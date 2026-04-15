module.exports = {
  port: process.env.PORT || 3000,
  jwt: {
    secret: process.env.JWT_SECRET || 'change_this_jwt_secret',
    expiresIn: '24h',
  },
  admin: {
    username: process.env.ADMIN_USERNAME || 'admin',
    password: process.env.ADMIN_PASSWORD || 'admin',
  },
  roomIdOffset: 1000,      // user room_id = 1000 + user.id (kept for DB compat)
};
