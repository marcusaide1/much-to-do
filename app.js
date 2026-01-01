const http = require('http');

const server = http.createServer((req, res) => {
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain');
  res.end('Hello! Your AWS Server is working!\n');
});

// IMPORTANT: Using '0.0.0.0' allows external access
server.listen(3000, '0.0.0.0', () => {
  console.log('Server is officially running at http://your-public-ip:3000/');
});
