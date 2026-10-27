# Release de Android

Cómo producir un APK/AAB **firmado** de Finanzas Personales. La primera distribución es un **APK directo** para ti y tus conocidos
(el AAB para Google Play se genera igual, pero la ficha de la tienda no está preparada; ver el final).

> El entorno de desarrollo en la nube no tiene Android SDK: el APK/AAB lo compila el CI (`release-android`) o tu propio equipo.

## 1. Lo que tienes que entender antes

- **La llave de firma es la identidad de la app.** Android solo instala una actualización si viene firmada con la **misma** llave
  que la versión instalada. Si la pierdes, tus usuarios tienen que desinstalar (y perder sus datos locales no sincronizados) para
  instalar una versión nueva. Hazle **dos respaldos** (gestor de contraseñas + otro lugar) antes de distribuir nada.
- **Nunca se sube al repositorio**: `*.jks`, `*.keystore` y `key.properties` están en `.gitignore`. En GitHub vive solo como *secreto*.
- El identificador de la app (`mx.finanzaspersonales.finanzas_personales`) **no se puede cambiar** después de publicar.
- Un release **exige una API con HTTPS**: Android bloquea el tráfico en claro y `10.0.2.2` solo existe en el emulador. Una
  compilación release sin `API_BASE_URL=https://…` arranca en una pantalla «App mal configurada» en vez de fallar en silencio.

## 2. Crear la llave (una sola vez)

En tu computadora (necesitas Java; `keytool` viene con él):

```bash
keytool -genkeypair -v -storetype PKCS12 -keystore finanzas-release.jks -alias finanzas \
  -keyalg RSA -keysize 2048 -validity 10000
```

- Elige **una** contraseña larga y úsala para el almacén y para la llave (en PKCS12 deben ser la misma).
- Anota el **SHA-256** del certificado (te servirá para comprobar que el CI firma con la llave correcta):
  `keytool -list -v -keystore finanzas-release.jks -alias finanzas | grep SHA256`
- Guarda `finanzas-release.jks` y la contraseña en dos lugares seguros. No la mandes por correo ni la pegues en un chat.

## 3. Compilar en tu equipo (opcional)

Crea `mobile/android/key.properties` (ignorado por git):

```properties
storeFile=/ruta/absoluta/finanzas-release.jks
storePassword=TU_CONTRASEÑA
keyAlias=finanzas
keyPassword=TU_CONTRASEÑA
```

```bash
cd mobile
flutter build apk --release --dart-define=API_BASE_URL=https://api.tu-dominio.mx --build-number=2
# salida: build/app/outputs/flutter-apk/app-release.apk
```

Sin llave configurada el build **falla** con un mensaje claro (no firma con la de depuración). Para una prueba local que
**no se distribuye**: `-PallowDebugSigning=true` en Gradle o `ALLOW_DEBUG_SIGNING=1`.

## 4. Compilar en GitHub (recomendado)

Configura una vez en *Settings → Secrets and variables → Actions*:

| Tipo | Nombre | Valor |
|---|---|---|
| Secreto | `ANDROID_KEYSTORE_BASE64` | `base64 -w0 finanzas-release.jks` (en macOS: `base64 -i finanzas-release.jks`) |
| Secreto | `ANDROID_KEYSTORE_PASSWORD` | la contraseña |
| Secreto | `ANDROID_KEY_ALIAS` | `finanzas` |
| Secreto | `ANDROID_KEY_PASSWORD` | la misma contraseña |
| Variable | `API_BASE_URL` | `https://api.tu-dominio.mx` |
| Variable (opcional) | `ANDROID_CERT_SHA256` | el SHA-256 del paso 2: el flujo falla si el certificado no coincide |

Luego, *Actions → release-android → Run workflow* con **`dry_run` desmarcado**. El flujo compila el APK y el AAB, **verifica**
que no están firmados con la llave de depuración, que el paquete es el correcto, que (si definiste `ANDROID_CERT_SHA256`) el
certificado coincide y que la URL de la API quedó compilada; después los deja como artefactos (30 días) y muestra el SHA-256 en
el resumen.

- Con `dry_run` marcado (y en todo PR que toque Android) usa una llave **desechable** y la URL que pongas o
  `https://api.ejemplo.invalid`: solo prueba que la cadena funciona. El artefacto se llama `…PRUEBA-no-distribuir`.
- `versionCode` = número de ejecución del flujo (siempre crece); `versionName` sale de `version:` en `mobile/pubspec.yaml`
  (súbelo a mano cuando cambie el producto: `1.1.0+1`).

## 5. Instalar el APK

1. Descarga el artefacto `finanzas-release` y descomprímelo; envía `app-release.apk` por el medio que prefieras.
2. En el teléfono: *Ajustes → Instalar apps desconocidas* para la app desde la que abras el archivo.
3. Las actualizaciones se instalan **encima** (misma llave y `versionCode` mayor); los datos locales y la sesión se conservan.

## 6. El servidor tiene que estar listo antes

El APK solo sirve si la API está en línea con HTTPS. Mínimo: un host con Node 22 y PostgreSQL 16, `npm ci && npm run migrate`,
variables de `backend/.env.example` (`DATABASE_URL`, `JWT_SECRET` largo y aleatorio, `TRUST_PROXY=1` detrás de un proxy), certificado TLS
(Caddy, nginx + Let's Encrypt o el que ofrezca tu proveedor) y **respaldos de la base**. El API ya purga tombstones a diario
(`TOMBSTONE_RETENTION_DAYS`). Nada de esto lo despliega el repositorio todavía.

## 7. Cuando quieras Google Play

Pendiente (no lo preparé porque elegiste APK directo): cuenta de desarrollador; subir el `.aab` y activar *Play App Signing*
(con tu llave actual como llave de subida); **política de privacidad** con URL pública (la app maneja datos financieros);
formulario de **seguridad de datos**; Google exige que las apps con cuenta tengan **eliminación de cuenta dentro de la app
(ya existe) y una URL web** para pedirla; ficha (descripción, capturas, ícono de 512 px, categoría Finanzas); y, para cuentas
personales nuevas, una prueba cerrada con testers antes de producción (revisa los requisitos vigentes). El `applicationId`
queda fijado en la primera subida.

## 8. Si algo falla

| Síntoma | Causa y arreglo |
|---|---|
| `Falta la llave de firma de release…` | No hay `key.properties` ni variables `ANDROID_KEYSTORE_*`. Ver pasos 3 y 4. |
| El CI dice `Falta un secreto de firma` | Falta alguno de los 4 secretos del paso 4. |
| El CI dice `El certificado … no coincide` | Subiste otra llave; revisa `ANDROID_KEYSTORE_BASE64` o corrige `ANDROID_CERT_SHA256`. |
| La app abre en «App mal configurada» | Se compiló sin `API_BASE_URL=https://…`. |
| «App no instalada» al actualizar | El APK nuevo está firmado con otra llave o tiene `versionCode` menor o igual. |
