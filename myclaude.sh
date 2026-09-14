#!/bin/bash
# myclaude.sh - Dynamic port manager and systemd launcher for MyClaude Proxy

MYCLAUDE_DIR="$HOME/myclaude"
cd "$MYCLAUDE_DIR" || exit 1

# Ensure virtual environment is active
if [ -z "$VIRTUAL_ENV" ] && [ -f venv/bin/activate ]; then
    source venv/bin/activate
fi

# Load environment variables
set -a
source .env
set +a

# Function to get a truly free port dynamically
get_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()'
}

case "$1" in
    start|"")
        echo "🚀 Starting MyClaude Proxy System..."

        # 1. CRITICAL: Clean up ALL old port and PID files to ensure a 100% fresh start
        echo "🧹 Cleaning up old port and PID files..."
        rm -f .litellm_port .nginx_port .litellm_pid .nginx_pid

        # 2. CRITICAL: Force rebuild config.yaml to ensure it is 100% up to date
        echo "🔨 Rebuilding config.yaml..."
        if [ -f build_config.sh ]; then
            ./build_config.sh
        else
            echo "❌ build_config.sh not found! Cannot proceed."
            exit 1
        fi

        # 3. Ensure ports are defined (generate dynamically)
        LITELLM_PORT=$(get_free_port)
        NGINX_PORT=$(get_free_port)
        
        # Save new ports to .env and local files
        echo "LITELLM_PORT=$LITELLM_PORT" >> .env
        echo "NGINX_PORT=$NGINX_PORT" >> .env
        echo "$LITELLM_PORT" > .litellm_port
        echo "$NGINX_PORT" > .nginx_port

        echo "✅ LiteLLM will run on dynamic port: $LITELLM_PORT"
        echo "✅ Nginx will run on dynamic port: $NGINX_PORT"

        # 4. Update systemd service with dynamic LiteLLM port
        echo "⚙️ Updating myclaude.service with dynamic port $LITELLM_PORT..."
        sudo sed -i "s/--port [0-9]\+/--port $LITELLM_PORT/g" /etc/systemd/system/myclaude.service
        sudo sed -i "s/Environment=\"PORT=[0-9]\+\"/Environment=\"PORT=$LITELLM_PORT\"/g" /etc/systemd/system/myclaude.service
        sudo systemctl daemon-reload

        # 5. Update Nginx configuration with dynamic ports
        echo "⚙️ Generating dynamic Nginx configuration for port $NGINX_PORT..."
        sudo mkdir -p /etc/nginx/conf.d

        cat << LIMIT_EOF | sudo tee /etc/nginx/conf.d/myclaude-limit.conf > /dev/null
# Rate limit zone by API Key (10 Requests Per Minute)
limit_req_zone \$http_authorization zone=api_key_limit:10m rate=10r/m;
LIMIT_EOF

        cat << NGINX_EOF | sudo tee /etc/nginx/sites-available/myclaude > /dev/null
server {
    listen $NGINX_PORT;
    listen [::]:$NGINX_PORT;
    server_name localhost _;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    client_max_body_size 50M;
    client_body_timeout 60s;
    client_header_timeout 60s;
    send_timeout 3600s;

    location / {
        limit_req zone=api_key_limit burst=5 nodelay;
        limit_req_status 429;
        limit_req_log_level warn;

        proxy_pass http://127.0.0.1:$LITELLM_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;

        proxy_buffering off;
        proxy_request_buffering off;
    }

    location = /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
NGINX_EOF

        sudo ln -sf /etc/nginx/sites-available/myclaude /etc/nginx/sites-enabled/myclaude

        # Test nginx config before proceeding
        if ! sudo nginx -t > /dev/null 2>&1; then
            echo "❌ Nginx configuration test failed!"
            sudo nginx -t
            exit 1
        fi

        # 6. ALWAYS restart myclaude.service to ensure it picks up the new dynamic port
        echo "⚙️ Restarting myclaude.service to apply new port..."
        sudo systemctl restart myclaude
        sleep 3

        # 7. Start or reload nginx
        if ! systemctl is-active --quiet nginx; then
            echo "⚙️ Starting nginx.service..."
            sudo systemctl start nginx
        else
            echo "⚙️ Reloading nginx.service to apply new config..."
            sudo systemctl reload nginx
        fi

        # 8. Verify health
        if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$NGINX_PORT/health" | grep -q "200"; then
            echo "✅ MyClaude Proxy is healthy and ready on port $NGINX_PORT!"
        else
            echo "⚠️ Proxy health check failed. Check 'myclaude status' for details."
        fi

        echo "💡 Tip: Type 'claude' to launch Claude Code connected to this proxy."
        ;;

    restart|--restart)
        echo "🔄 Restarting MyClaude Proxy System..."
        # This will automatically trigger the cleanup and build_config.sh in the start block
        exec "$0" start
        ;;

    status)
        echo "📊 MyClaude Status:"
        echo "--- myclaude.service ---"
        systemctl status myclaude --no-pager -n 10
        echo ""
        echo "--- nginx.service ---"
        systemctl status nginx --no-pager -n 10
        ;;

    stop)
        echo "🛑 Stopping MyClaude Proxy System..."
        sudo systemctl stop myclaude
        sudo systemctl stop nginx
        # Clean up files on stop
        rm -f .litellm_port .nginx_port .litellm_pid .nginx_pid
        echo "✅ Stopped and cleaned up."
        ;;

    *)
        echo "Usage: myclaude [start|restart|--restart|status|stop]"
        ;;
esac
