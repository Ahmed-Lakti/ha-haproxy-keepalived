FROM docker.io/library/nginx:1.27-alpine
COPY default.conf /etc/nginx/conf.d/default.conf
COPY 40-index.sh /docker-entrypoint.d/40-index.sh
RUN chmod +x /docker-entrypoint.d/40-index.sh
