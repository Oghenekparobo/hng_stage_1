#!/bin/sh
# deploy.sh - Automates deployment of a Dockerized application

# Initialize logging
LOGFILE="deploy_$(date +%Y%m%d_%H%M%S).log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOGFILE"
    echo "$1"
}

# Error handling
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Trap unexpected errors
trap 'error_exit "Script terminated unexpectedly at line $LINENO"' ERR

# Check for cleanup flag
if [ "$1" = "--cleanup" ]; then
    log "Cleaning up resources on $VPS_IP..."
    ssh -i "$SSH_KEY" "$SSH_USER@$VPS_IP" << 'EOF' || error_exit "Cleanup failed"
        log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /root/deploy.log; echo "$1"; }
        if [ -d "/home/$SSH_USER/$REPO_NAME" ]; then
            cd "/home/$SSH_USER/$REPO_NAME" || exit 1
            if [ -f "docker-compose.yml" ]; then
                docker compose down || true
            else
                docker stop $REPO_NAME || true
                docker rm $REPO_NAME || true
            fi
            rm -rf "/home/$SSH_USER/$REPO_NAME"
        fi
        rm -f /etc/nginx/sites-available/$REPO_NAME
        rm -f /etc/nginx/sites-enabled/$REPO_NAME
        systemctl reload nginx || true
        log "Cleanup completed"
        exit 0
    EOF
    log "Cleanup completed successfully"
    exit 0
fi

# Collect and validate user input
log "Collecting user input..."
read -p "Enter Git Repository URL (e.g., https://github.com/mendhak/docker-http-server): " GIT_URL
[ -z "$GIT_URL" ] && error_exit "Git Repository URL is required"
read -p "Enter Personal Access Token: " GIT_PAT
[ -z "$GIT_PAT" ] && error_exit "Personal Access Token is required"
read -p "Enter branch name (default: main): " GIT_BRANCH
GIT_BRANCH=${GIT_BRANCH:-main}
read -p "Enter SSH username (e.g., root): " SSH_USER
[ -z "$SSH_USER" ] && error_exit "SSH username is required"
read -p "Enter VPS IP address (e.g., 72.61.164.211): " VPS_IP
[ -z "$VPS_IP" ] && error_exit "VPS IP address is required"
read -p "Enter SSH key path (e.g., ~/.ssh/id_ed25519): " SSH_KEY
[ -z "$SSH_KEY" ] && error_exit "SSH key path is required"
[ ! -f "$SSH_KEY" ] && error_exit "SSH key file does not exist"
read -p "Enter application port (e.g., 8000): " APP_PORT
[ -z "$APP_PORT" ] && error_exit "Application port is required"
case $APP_PORT in
    ''|*[!0-9]*) error_exit "Application port must be a number" ;;
esac

# Clone or update the repository
log "Cloning or updating repository..."
REPO_NAME=$(basename "$GIT_URL" .git)
if [ -d "$REPO_NAME" ]; then
    log "Repository directory $REPO_NAME exists, pulling latest changes..."
    cd "$REPO_NAME" || error_exit "Failed to enter repository directory"
    git -c http.extraHeader="Authorization: Bearer $GIT_PAT" pull origin "$GIT_BRANCH" || error_exit "Failed to pull repository"
else
    log "Cloning repository $GIT_URL..."
    git clone -b "$GIT_BRANCH" --config http.extraHeader="Authorization: Bearer $GIT_PAT" "$GIT_URL" || error_exit "Failed to clone repository"
    cd "$REPO_NAME" || error_exit "Failed to enter repository directory"
fi
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
    log "Dockerfile or docker-compose.yml found"
else
    error_exit "No Dockerfile or docker-compose.yml found in repository"
fi

# Install prerequisites on VPS
log "Installing prerequisites on $VPS_IP..."
ssh -i "$SSH_KEY" "$SSH_USER@$VPS_IP" << 'EOF' || error_exit "Failed to install prerequisites"
    log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /root/deploy.log; echo "$1"; }
    apt-get update -y && apt-get upgrade -y
    apt-get install -y git curl
    if ! command -v docker >/dev/null 2>&1; then
        log "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        systemctl enable docker
        systemctl start docker
        usermod -aG docker "$USER"
    fi
    docker --version && log "Docker installed: $(docker --version)"
    if ! command -v docker-compose >/dev/null 2>&1; then
        log "Installing Docker Compose..."
        apt-get install -y docker-compose-plugin
    fi
    docker compose version && log "Docker Compose installed: $(docker compose version)"
    if ! command -v nginx >/dev/null 2>&1; then
        log "Installing Nginx..."
        apt-get install -y nginx
        systemctl enable nginx
        systemctl start nginx
    fi
    nginx -v && log "Nginx installed: $(nginx -v 2>&1)"
    log "Prerequisites installed successfully"
EOF

# Deploy application
log "Deploying application to $VPS_IP..."
scp -i "$SSH_KEY" -r "$REPO_NAME" "$SSH_USER@$VPS_IP:/home/$SSH_USER/$REPO_NAME" || error_exit "Failed to transfer files"
ssh -i "$SSH_KEY" "$SSH_USER@$VPS_IP" << EOF || error_exit "Failed to deploy application"
    log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /root/deploy.log; echo "$1"; }
    if [ -d "/home/$SSH_USER/$REPO_NAME" ]; then
        cd "/home/$SSH_USER/$REPO_NAME" || exit 1
        if [ -f "docker-compose.yml" ]; then
            docker compose down || true
        else
            docker stop $REPO_NAME || true
            docker rm $REPO_NAME || true
        fi
    fi
    cd "/home/$SSH_USER/$REPO_NAME" || exit 1
    log "Building and running Docker containers..."
    if [ -f "docker-compose.yml" ]; then
        docker compose up -d --build || exit 1
    else
        docker build -t $REPO_NAME . || exit 1
        docker run -d -p $APP_PORT:$APP_PORT --name $REPO_NAME $REPO_NAME || exit 1
    fi
    if docker ps | grep "$REPO_NAME" >/dev/null; then
        log "Container $REPO_NAME is running"
    else
        exit 1
    fi
    docker logs "$REPO_NAME" >> /root/deploy.log 2>&1
    log "Application deployed successfully"
EOF

# Configure Nginx
log "Configuring Nginx on $VPS_IP..."
ssh -i "$SSH_KEY" "$SSH_USER@$VPS_IP" << EOF || error_exit "Failed to configure Nginx"
    log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /root/deploy.log; echo "$1"; }
    cat > /etc/nginx/sites-available/$REPO_NAME << 'NGINX_CONF'
server {
    listen 80;
    server_name $VPS_IP;
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_CONF
    ln -sf /etc/nginx/sites-available/$REPO_NAME /etc/nginx/sites-enabled/$REPO_NAME
    nginx -t || exit 1
    systemctl reload nginx
    log "Nginx configured and reloaded"
EOF

# Validate deployment
log "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$VPS_IP" << EOF || error_exit "Failed to validate deployment"
    log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /root/deploy.log; echo "$1"; }
    if systemctl is-active docker >/dev/null; then
        log "Docker service is running"
    else
        exit 1
    fi
    if docker ps | grep "$REPO_NAME" >/dev/null; then
        log "Container $REPO_NAME is healthy"
    else
        exit 1
    fi
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost" | grep "200" >/dev/null; then
        log "Nginx is proxying correctly"
    else
        exit 1
    fi
    if curl -s "http://localhost:$APP_PORT" >/dev/null; then
        log "Application is accessible on port $APP_PORT"
    else
        exit 1
    fi
    log "Deployment validated successfully"
EOF

log "Deployment completed successfully"