#cloud-config
# Шаблон cloud-init для машин стенда ДЗ 1.
# Плейсхолдеры в двойных фигурных скобках подставляет create.sh отдельно для каждой машины.
# Веб-серверы и сервер приложения настраиваются одинаково: nginx на порту
# сервиса, страница со словом варианта и именем машины. Различается только роль.

users:
  - name: {{SSH_USER}}
    groups: sudo
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "{{SSH_KEY}}"

package_update: true
packages:
  - nginx
  - curl

write_files:
  - path: /etc/nginx/conf.d/hw01.conf
    content: |
      # слушаем порт сервиса на всех адресах (0.0.0.0), а не только на 127.0.0.1
      server {
          listen {{PORT}};
          server_name _;
          root /var/www/hw01;
          index index.html;
          location / {
              try_files $uri $uri/ =404;
          }
      }
  - path: /var/www/hw01/index.html
    content: |
      <!doctype html>
      <html lang="ru">
      <head><meta charset="utf-8"><title>{{WORD}}</title></head>
      <body>
        <h1>{{WORD}}</h1>
        <p>host: {{HOST}}</p>
        <p>role: {{ROLE}}</p>
      </body>
      </html>

runcmd:
  # стандартный сайт на 80-м порту не нужен: наружу смотрит только порт сервиса
  - rm -f /etc/nginx/sites-enabled/default
  - systemctl enable nginx
  - systemctl restart nginx
