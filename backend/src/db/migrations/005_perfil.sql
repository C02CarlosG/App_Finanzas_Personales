-- Perfil de usuario (Paso 7). token_version invalida los JWT ya emitidos: se incrementa al
-- cambiar la contraseña y al cerrar sesión en todos los dispositivos. El token lleva el valor
-- con que se firmó ("ver") y el middleware de auth lo compara con esta columna.
ALTER TABLE users ADD COLUMN token_version INT NOT NULL DEFAULT 0;
