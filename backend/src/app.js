const express = require('express');
const auth = require('./middleware/auth');
const errorHandler = require('./middleware/errorHandler');
const { notFound } = require('./utils/errors');

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '1mb' }));

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.use('/auth', require('./routes/auth'));
app.use('/banks', auth, require('./routes/banks'));
app.use('/accounts', auth, require('./routes/accounts'));
app.use('/categories', auth, require('./routes/categories'));
app.use('/transactions', auth, require('./routes/transactions'));
app.use('/dashboard', auth, require('./routes/dashboard'));
app.use('/sync', auth, require('./routes/sync'));

app.use((_req, _res, next) => next(notFound('Ruta')));
app.use(errorHandler);

module.exports = app;
