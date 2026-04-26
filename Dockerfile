FROM node:20-alpine
WORKDIR /app
RUN apk upgrade --no-cache && npm install -g npm@latest
COPY package*.json ./
RUN npm install
COPY . .
EXPOSE 5000
CMD ["node", "index.js"]