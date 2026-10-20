const config = require('./config');

if (!config.databaseUrl || !config.jwtSecret) {
  console.error('Faltan DATABASE_URL o JWT_SECRET (ver .env.example)');
  process.exit(1);
}

const app = require('./app');
app.listen(config.port, () => console.log(`API escuchando en :${config.port}`));
