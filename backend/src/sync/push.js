const { ENTITIES } = require('./entities');

const MAX_FUTURE_MS = 5 * 60 * 1000;

const result = (change, status, extra = {}) => ({ table: change.table, id: change.id, status, ...extra });

async function fetchRecord(client, ent, id) {
  const { rows } = await client.query(`SELECT ${ent.select} FROM ${ent.table} t WHERE t.id = $1`, [id]);
  return rows[0] ?? null;
}

// Un cambio con relojes del dispositivo adelantados no puede ganar para siempre:
// si client_updated_at excede la hora del servidor por más de 5 min, se acota a la hora del servidor.
function clampTimestamp(clientTs, serverNow) {
  return Date.parse(clientTs) > serverNow.getTime() + MAX_FUTURE_MS ? serverNow.toISOString() : clientTs;
}

async function applyDelete(client, userId, change, ent, existing) {
  // Borrar algo que el servidor no conoce (o que no es del usuario) no es un error: nada que hacer.
  if (!existing || existing.user_id !== userId) return result(change, 'applied', { record: null });
  if (existing.deleted_at) return result(change, 'applied', { record: await fetchRecord(client, ent, change.id) });
  const blocked = await ent.blockDelete(client, userId, existing);
  if (blocked) return result(change, 'rejected', { ...blocked, record: await fetchRecord(client, ent, change.id) });
  await client.query(`UPDATE ${ent.table} SET deleted_at = now() WHERE id = $1`, [change.id]);
  return result(change, 'applied', { record: await fetchRecord(client, ent, change.id) });
}

async function applyUpsert(client, userId, change, ent, existing, serverNow) {
  const parsed = ent.schema.safeParse(change.data);
  if (!parsed.success) {
    const message = parsed.error.issues.map((i) => `${i.path.join('.') || 'data'}: ${i.message}`).join('; ');
    return result(change, 'invalid', { code: 'validation_error', message });
  }
  const data = parsed.data;
  if (existing && existing.user_id !== userId) {
    return result(change, 'invalid', { code: 'invalid_id', message: 'Identificador no disponible' });
  }
  // Tombstone gana a cualquier edición, sin importar su fecha.
  if (existing?.deleted_at) {
    return result(change, 'deleted', { record: await fetchRecord(client, ent, change.id) });
  }
  const clientTs = clampTimestamp(change.client_updated_at, serverNow);

  if (existing) {
    for (const col of ent.immutable) {
      if (existing[col] !== data[col]) {
        return result(change, 'invalid', { code: 'immutable_field', message: `${col} no se puede modificar` });
      }
    }
    // Se compara en SQL: un Date de JS truncaría los microsegundos de client_updated_at.
    const newer = (await client.query(
      `SELECT $1::timestamptz > client_updated_at AS newer FROM ${ent.table} WHERE id = $2`, [clientTs, change.id])).rows[0].newer;
    // Empate o más viejo: gana el servidor. El cliente adopta record (también cubre reintentos idempotentes).
    if (!newer) return result(change, 'stale', { record: await fetchRecord(client, ent, change.id) });
    const rejected = ent.checkUpdate(existing, data);
    if (rejected) return result(change, 'rejected', { ...rejected, record: await fetchRecord(client, ent, change.id) });
  }

  const refError = await ent.validateRefs(client, userId, data, existing);
  if (refError) return result(change, 'invalid', refError);

  if (existing) {
    const sets = ent.dataCols.map((c, i) => `${c} = $${i + 2}`).concat(`client_updated_at = $${ent.dataCols.length + 2}`);
    await client.query(`UPDATE ${ent.table} SET ${sets.join(', ')} WHERE id = $1`,
      [change.id, ...ent.dataCols.map((c) => data[c]), clientTs]);
  } else {
    const cols = ['id', 'user_id', ...ent.dataCols, 'client_updated_at'];
    await client.query(
      `INSERT INTO ${ent.table} (${cols.join(', ')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')})`,
      [change.id, userId, ...ent.dataCols.map((c) => data[c]), clientTs]);
  }
  return result(change, 'applied', { record: await fetchRecord(client, ent, change.id) });
}

// Errores de BD esperables por cambio (el savepoint ya revirtió sus escrituras).
async function mapDbError(client, userId, change, err) {
  if (err.code === '23505') {
    if (change.table === 'categories' && change.data?.name && change.data?.kind) {
      const dup = await client.query(
        `SELECT id FROM categories WHERE user_id = $1 AND kind = $2 AND lower(name) = lower($3) AND deleted_at IS NULL`,
        [userId, change.data.kind, String(change.data.name).trim()]);
      if (dup.rowCount) {
        return result(change, 'rejected', { code: 'duplicate_name', message: 'Ya existe una categoría con ese nombre', conflicting_id: dup.rows[0].id });
      }
    }
    return result(change, 'rejected', { code: 'conflict', message: 'Conflicto de escritura concurrente; reintenta' });
  }
  if (err.code === '23503') return result(change, 'invalid', { code: 'invalid_reference', message: 'Referencia inválida' });
  if (err.code && err.code.startsWith('22')) return result(change, 'invalid', { code: 'validation_error', message: 'Dato inválido' });
  return null;
}

// Aplica un lote dentro de la transacción recibida. Resultados en el mismo orden que la entrada.
async function applyChanges(client, userId, changes) {
  const serverNow = (await client.query('SELECT now() AS now')).rows[0].now;
  const results = new Array(changes.length);

  // Altas/ediciones: padres primero. Borrados: hijos primero.
  const indexed = changes.map((change, i) => ({ change, i }));
  const upserts = indexed.filter((x) => !x.change.deleted).sort((a, b) => ENTITIES[a.change.table].order - ENTITIES[b.change.table].order);
  const deletes = indexed.filter((x) => x.change.deleted).sort((a, b) => ENTITIES[b.change.table].order - ENTITIES[a.change.table].order);

  for (const { change, i } of [...upserts, ...deletes]) {
    const ent = ENTITIES[change.table];
    await client.query('SAVEPOINT change');
    try {
      const existing = (await client.query(`SELECT * FROM ${ent.table} WHERE id = $1 FOR UPDATE`, [change.id])).rows[0];
      results[i] = change.deleted
        ? await applyDelete(client, userId, change, ent, existing)
        : await applyUpsert(client, userId, change, ent, existing, serverNow);
      await client.query('RELEASE SAVEPOINT change');
    } catch (err) {
      await client.query('ROLLBACK TO SAVEPOINT change');
      const mapped = await mapDbError(client, userId, change, err);
      if (!mapped) throw err;
      results[i] = mapped;
    }
  }
  return { results, serverNow };
}

module.exports = { applyChanges };
