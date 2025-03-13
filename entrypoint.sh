#!/bin/bash
set -e

echo "🚀 Starting Docker Deploy Action"

# Create temporary SSH key file
DEPLOY_KEY_PATH=$(mktemp)

echo "$SSH_KEY" > "$DEPLOY_KEY_PATH"
chmod 600 "$DEPLOY_KEY_PATH"

# Determine which files to upload based on mode
if [ "$MODE" == "stack" ]; then
    FILES="$STACK_FILES"
else
    FILES="$COMPOSE_FILES"
fi

# Build list of files to upload (main files + extra files)
IFS=',' read -ra FILE_LIST <<< "$FILES"
IFS=',' read -ra EXTRA_FILES_LIST <<< "$EXTRA_FILES"

ALL_FILES=("${FILE_LIST[@]}" "${EXTRA_FILES_LIST[@]}")

if [ ${#ALL_FILES[@]} -eq 0 ]; then
    echo "❌ No files specified for upload"
    exit 1
fi

# Upload all files in a single scp command
for file in "${ALL_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ Required file $file not found"
        exit 1
    fi
done

# Ensure project path exists
echo "📂 Checking if project path exists on remote server: $PROJECT_PATH"

ssh -i "$DEPLOY_KEY_PATH" -o StrictHostKeyChecking=no -p "$SSH_PORT" -T "$SSH_USER@$SSH_HOST" <<EOF
if [ ! -d "$PROJECT_PATH" ]; then
    echo '📁 Project path not found - creating it...'
    sudo mkdir -p "$PROJECT_PATH"
    sudo chown "$SSH_USER":"$SSH_USER" "$PROJECT_PATH"
    sudo chmod 750 "$PROJECT_PATH"

    # Explicitly check that it exists after creation
    if [ ! -d "$PROJECT_PATH" ]; then
        echo '❌ Failed to create project path!'
        exit 1
    fi

    echo '✅ Project path created and verified.'
else
    echo '✅ Project path already exists.'
fi
EOF

# Upload all files
echo "📂 Uploading files to $SSH_USER@$SSH_HOST:$PROJECT_PATH"

scp -i "$DEPLOY_KEY_PATH" -o StrictHostKeyChecking=no -P "$SSH_PORT" "${ALL_FILES[@]}" "$SSH_USER@$SSH_HOST:$PROJECT_PATH/"

echo "🔗 Connecting to $SSH_USER@$SSH_HOST to deploy..."

# Connect to remote server to deploy
ssh -i "$DEPLOY_KEY_PATH" -o StrictHostKeyChecking=no -p "$SSH_PORT" -T "$SSH_USER@$SSH_HOST" <<EOF
set -e

echo "✅ Connected to $SSH_HOST"

# Verify all uploaded files exist
for file in ${ALL_FILES[@]}; do
    filename=\$(basename "\$file")
    if [ ! -f "$PROJECT_PATH/\$filename" ]; then
        echo "❌ Missing file after upload: \$filename"
        exit 1
    fi
done

echo "✅ All files verified on server"

# Create network if needed
if [ -n "$DOCKER_NETWORK" ]; then
    echo "🌐 Ensuring network $DOCKER_NETWORK exists"

    if ! docker network inspect "$DOCKER_NETWORK" > /dev/null 2>&1; then
        if [ -z "$DOCKER_NETWORK_DRIVER" ]; then
            if [ "$MODE" == "stack" ]; then
                DOCKER_NETWORK_DRIVER="overlay"
            else
                DOCKER_NETWORK_DRIVER="bridge"
            fi
        fi

        echo "🔧 Creating $DOCKER_NETWORK network with driver $DOCKER_NETWORK_DRIVER"

        if [ "$MODE" == "stack" ]; then
            docker network create \
                --driver "$DOCKER_NETWORK_DRIVER" \
                --scope swarm \
                --attachable \
                "$DOCKER_NETWORK"
        else
            docker network create \
                --driver "$DOCKER_NETWORK_DRIVER" \
                "$DOCKER_NETWORK"
        fi

        if docker network inspect "$DOCKER_NETWORK" > /dev/null 2>&1; then
            echo "✅ Network $DOCKER_NETWORK successfully created"
        else
            echo "❌ Network creation failed for $DOCKER_NETWORK!"
            exit 1
        fi
    else
        echo "✅ Network $DOCKER_NETWORK already exists"
    fi
fi

echo "📦 Changing directory to $PROJECT_PATH"
cd $PROJECT_PATH

# Optional Registry Login
if [ -n "$REGISTRY_HOST" ] && [ -n "$REGISTRY_USER" ] && [ -n "$REGISTRY_PASS" ]; then
    echo "🔑 Logging into container registry: $REGISTRY_HOST"
    echo "$REGISTRY_PASS" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin
else
    echo "⏭️ Skipping container registry login - credentials not provided"
fi

# Deploy stack or compose services
if [ "$MODE" == "stack" ]; then
    echo "⚓ Deploying stack $STACK_NAME using Docker Swarm"
    docker stack deploy -c ${FILES//,/ -c } $STACK_NAME --with-registry-auth --detach=false

    echo "✅ Verifying services in stack $STACK_NAME"
    docker service ls --filter "label=com.docker.stack.namespace=$STACK_NAME"
    
    # Verify stack services are running
    if ! docker service ls --filter "label=com.docker.stack.namespace=$STACK_NAME" | grep -v REPLICAS | grep -q " 0/"; then
        echo "✅ All services in stack $STACK_NAME are running correctly"
    else
        echo "❌ One or more services failed to start in stack $STACK_NAME!"
        docker service ls --filter "label=com.docker.stack.namespace=$STACK_NAME"
        exit 1
    fi
else
    echo "🐳 Deploying using Docker Compose"
    docker-compose pull
    docker-compose down
    docker-compose up -d

    echo "✅ Verifying Compose services"

    # Verify all compose services are running
    if docker-compose ps | grep -E "Exit|Restarting|Dead"; then
        echo "❌ One or more services failed to start!"
        docker-compose ps
        exit 1
    else
        echo "✅ All services are running"
        docker-compose ps
    fi
fi

# Run optional docker prune (type: system, volumes, networks, images, containers, none)
case "$DOCKER_PRUNE" in
    system)
        echo "🧹 Running full system prune (images, containers, volumes, networks)"
        docker system prune -f
        ;;
    volumes)
        echo "📦 Running volume prune (removing unused volumes)"
        docker volume prune -f
        ;;
    networks)
        echo "🌐 Running network prune (removing unused networks)"
        docker network prune -f
        ;;
    images)
        echo "🖼️ Running image prune (removing unused images)"
        docker image prune -f
        ;;
    containers)
        echo "📦 Running container prune (removing stopped containers)"
        docker container prune -f
        ;;
    none|"")
        echo "⏭️ Skipping docker prune"
        ;;
    *)
        echo "❌ Invalid prune type: $DOCKER_PRUNE"
        exit 1
        ;;
esac

EOF

# Cleanup SSH key
rm -f "$DEPLOY_KEY_PATH"

echo "✅ Deployment complete"
