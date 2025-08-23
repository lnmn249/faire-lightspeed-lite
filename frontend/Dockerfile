# Build Vue app
FROM node:20-slim AS build
WORKDIR /app
COPY package*.json ./
ENV NODE_ENV=development
RUN npm ci || npm i
COPY . .
# Fix execute perms just in case
RUN chmod +x node_modules/.bin/* || true
RUN npm run build


# Serve with Nginx
FROM nginx:stable-alpine

# Copy build output
COPY --from=build /app/dist /usr/share/nginx/html

# Copy templates for runtime substitution
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY public/config.template.js /usr/share/nginx/html/config.template.js

# Remove default site config
RUN rm /etc/nginx/conf.d/default.conf

# Expose Cloud Run port
ENV PORT=8080

# On startup, substitute env vars into templates, then run nginx
# CMD ["/bin/sh", "-c", \
#  "envsubst < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf && \
#   envsubst < /usr/share/nginx/html/config.template.js > /usr/share/nginx/html/config.js && \
#   nginx -g 'daemon off;'"]
CMD ["/bin/sh","-c", "\
  envsubst '${PORT}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf && \
  envsubst '${VITE_API_URL}' < /usr/share/nginx/html/config.template.js > /usr/share/nginx/html/config.js && \
  nginx -g 'daemon off;'"]
