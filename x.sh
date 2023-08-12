#!/bin/bash

# Function to check and install necessary tools
check_and_install() {
    for tool in "$@"; do
        if ! command -v "$tool" &> /dev/null; then
            echo "$tool is not installed. Installing..."
            if [[ "$tool" == "docker" ]]; then
                curl -fsSL get.docker.com -o get-docker.sh && sh get-docker.sh
            else
                sudo apt-get update
                sudo apt-get install -y "$tool"
            fi
        fi
    done
}


# Check and install jq, curl, docker if not present
check_and_install jq docker curl

# IRCF Script

# Parse the IRCF export
IRCF_DATA=$(curl -s "https://ircf.space/export.php")


# Ask for Cloudflare token
read -p "Enter your Cloudflare token: " TOKEN

# List all domains under the Cloudflare account
DOMAINS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" | jq -r '.result[] | .name')

# Display domains and ask user to choose
echo "Select domain to create IRCF CNAME records:"
select DOMAIN in $DOMAINS; do
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')
    break
done

# Function to create CNAME and A records on Cloudflare
create_dns_record() {
    local domain="$1"
    local name="$2"
    local type="$3"
    local content="$4"
    local token="$5"
    local zone_id="$6"
    local proxied="$7"

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\",\"proxied\":$proxied}" > /dev/null
}


echo "Creating CNAME records..."
while IFS=$'\t' read -r TARGET _; do
    # Extract subdomain from the target
    SUBDOMAIN=$(echo "$TARGET" | cut -d'.' -f1)
    create_dns_record "$DOMAIN" "$SUBDOMAIN.$DOMAIN" "CNAME" "$TARGET" "$TOKEN" "$ZONE_ID" "false"
    echo "Created CNAME: $SUBDOMAIN.$DOMAIN -> $TARGET"
done <<< "$IRCF_DATA"

echo "All CNAME records created successfully!"

# Ask for Marzban Panel domain and subdomain
echo "Select a domain for Marzban Panel:"
select MARZBAN_DOMAIN in $DOMAINS; do
    break
done

read -p "Enter a subdomain for Marzban Panel (e.g., marzban): " MARZBAN_SUBDOMAIN

# Get server's public IP address
SERVER_IP=$(curl -s ifconfig.me)

# Create A record for the subdomain
create_dns_record "$MARZBAN_DOMAIN" "$MARZBAN_SUBDOMAIN" "A" "$SERVER_IP" "$TOKEN" "$ZONE_ID" "true"
echo "A record for $MARZBAN_SUBDOMAIN.$MARZBAN_DOMAIN pointing to $SERVER_IP created successfully!"

# Ask for Request Host domain and subdomain
echo "Select a domain for Request Host:"
select REQUEST_HOST_DOMAIN in $DOMAINS; do
    break
done

read -p "Enter a subdomain for Request Host (e.g., requesthost): " REQUEST_HOST_SUBDOMAIN

# Create A record for the Request Host subdomain
create_dns_record "$REQUEST_HOST_DOMAIN" "$REQUEST_HOST_SUBDOMAIN" "A" "$SERVER_IP" "$TOKEN" "$ZONE_ID" "true"
echo "A record for $REQUEST_HOST_SUBDOMAIN.$REQUEST_HOST_DOMAIN pointing to $SERVER_IP created successfully!"

# Ask for paths for vmess, vless, and trojan
read -p "Enter the path for vmess (e.g., /vmess): " VM_PATH
read -p "Enter the path for vless (e.g., /vless): " VL_PATH
read -p "Enter the path for trojan (e.g., /trojan): " TR_PATH

# Create nginx.conf file
cat <<EOL > nginx.conf
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;

    server {
        listen 80 default_server;
        server_name $MARZBAN_SUBDOMAIN.$MARZBAN_DOMAIN;

        location ~* ^\\/(dashboard|api|sub|docs|openapi.json).* {
            proxy_pass http://localhost:8000;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location $TR_PATH {
            proxy_pass http://127.0.0.1:7777;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }

        location $VM_PATH {
            proxy_pass http://127.0.0.1:6666;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }

        location $VL_PATH {
            proxy_pass http://127.0.0.1:5555;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
EOL

echo "nginx.conf file created successfully!"


# Ask for Marzban Panel credentials
read -p "Enter Marzban Panel username: " MARZBAN_USER
read -p "Enter Marzban Panel password: " MARZBAN_PASS

# Create docker-compose.yml file
cat <<EOL > docker-compose.yml
services:
  marzban:
    image: gozargah/marzban:latest
    restart: always
    network_mode: host
    hostname: marzban
    environment:
      SQLALCHEMY_DATABASE_URL: "sqlite:////var/lib/marzban/db.sqlite3"
      UVICORN_HOST: 127.0.0.1
      UVICORN_PORT: 8000
      SUDO_USERNAME: $MARZBAN_USER
      SUDO_PASSWORD: $MARZBAN_PASS
      XRAY_JSON: "/var/lib/marzban/xray.json"
      XRAY_SUBSCRIPTION_URL_PREFIX: "https://$MARZBAN_SUBDOMAIN.$MARZBAN_DOMAIN"
      DOCS: true
    volumes:
      - /var/lib/marzban/run:/run
      - ./:/var/lib/marzban
  nginx:
    image: nginx:alpine
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
EOL

echo "docker-compose.yml file updated successfully!"

# Create xray.json file
cat <<EOL > xray.json
{
	"inbounds": [{
			"port": 5555,
			"listen": "127.0.0.1",
			"protocol": "vless",
			"tag": "vless-in",
			"settings": {
				"clients": [],
				"decryption": "none"
			},
			"streamSettings": {
				"network": "ws",
				"security": "none",
				"wsSettings": {
					"path": "$VL_PATH"
				}
			}
		},
		{
			"port": 6666,
			"listen": "127.0.0.1",
			"protocol": "vmess",
			"tag": "vmess-in",
			"settings": {
				"clients": [],
				"decryption": "none",
				"disableInsecureEncryption": true
			},
			"streamSettings": {
				"network": "ws",
				"security": "none",
				"wsSettings": {
					"path": "$VM_PATH",
					"headers": {}
				}
			}
		},
		{
			"port": 7777,
			"listen": "127.0.0.1",
			"protocol": "trojan",
			"tag": "trojan-in",
			"settings": {
				"clients": []
			},
			"streamSettings": {
				"network": "ws",
				"security": "none",
				"wsSettings": {
					"path": "$TR_PATH"
				}
			}
		}
	],
	"outbounds": [{
			"protocol": "freedom",
			"tag": "DIRECT"
		},
		{
			"protocol": "blackhole",
			"tag": "BLOCK"
		}
	],
	"routing": {
		"rules": [{
			"ip": [
				"geoip:private"
			],
			"domain": [
				"geosite:private"
			],
			"protocol": [
				"bittorrent"
			],
			"outboundTag": "BLOCK",
			"type": "field"
		}]
	}
}
EOL


echo "xray.json file updated successfully!"




# Fetch and extract domains
content=$(curl -s "https://raw.githubusercontent.com/yebekhe/TelegramV2rayCollector/main/sub/reality")
domains=$(echo "$content" | grep -o 'sni=[^&]*' | awk -F= '{print $2}' | grep '\.' | sort | uniq)

# Initial ports for gRPC inbounds
grpc_ports=(2052 2053 2082 2083 2086 2087 2095 2096 3306 3089 1433 5000 5432 5224 8447 8080 8443 8880)

# Generate the inbounds for xray.json
inbounds=""
grpc_inbounds=""
counter=1
grpc_counter=0
for domain in $domains; do
    # VLESS inbound
    inbound=$(cat <<EOL
        {
            "tag": "vless-reality$counter",
            "listen": "127.0.0.1",
            "port": $((8000 + counter)),
            "protocol": "vless",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "tcpSettings": {
                    "acceptProxyProtocol": true
                },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$domain:443",
                    "xver": 0,
                    "serverNames": [
                        "$domain"
                    ],
                    "privateKey": "MMX7m0Mj3faUstoEm5NBdegeXkHG6ZB78xzBv2n3ZUA",
                    "shortIds": [
                        "",
                        "0123456789abcdef"
                    ]
                }
            }
        },
EOL
)
    inbounds+="$inbound"

    # gRPC inbound
    if [ $grpc_counter -lt ${#grpc_ports[@]} ]; then
        port=${grpc_ports[$grpc_counter]}
    else
        port=$((50050 + grpc_counter - ${#grpc_ports[@]} + 1))
    fi
    grpc_inbound=$(cat <<EOL
        {
            "tag": "grpc-reality$counter",
            "listen": "::",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "grpc",
                "grpcSettings": {
                    "serviceName": "bitcoinvps.cloud"
                },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$domain:443",
                    "xver": 0,
                    "serverNames": [
                        "$domain"
                    ],
                    "privateKey": "MMX7m0Mj3faUstoEm5NBdegeXkHG6ZB78xzBv2n3ZUA",
                    "shortIds": [
                        "",
                        "6ba85179e30d4fc2"
                    ]
                }
            }
        },
EOL
)
    grpc_inbounds+="$grpc_inbound"

    ((counter++))
    ((grpc_counter++))
done

# Remove the trailing comma from the last inbounds
inbounds=${inbounds%,}
grpc_inbounds=${grpc_inbounds%,}

# Combine VLESS and gRPC inbounds
all_inbounds="$inbounds,$grpc_inbounds"

# Extract the current inbounds from xray.json and append the new inbounds to it
jq ".inbounds += [$all_inbounds]" xray.json > xray_temp.json && mv xray_temp.json xray.json

# Generate the stream block for nginx.conf (keeping as previously provided)
map_entries=""
upstream_entries="upstream marzban {\n    server 127.0.0.1:8000;\n}\n"
counter=1
for domain in $domains; do
    map_entries+="$domain vless-reality$counter;\n"
    upstream_entries+="upstream vless-reality$counter {\n    server 127.0.0.1:$((8000 + counter));\n}\n"
    ((counter++))
done

stream_block=$(cat <<EOL
stream {
    map \$ssl_preread_server_name \$bitcoinvps {
        $map_entries
    }

    $upstream_entries

    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        proxy_pass \$bitcoinvps;
        ssl_preread on;
        proxy_protocol on;
    }
}
EOL
)

# Append the stream block to nginx.conf
echo -e "\n$stream_block" >> nginx.conf

echo "Scripts updated successfully!"



docker compose up -d



# Function to generate data for each inbound based on the IRCF data
generate_inbound_data() {
    local inbound="$1"
    local data=""
    while IFS=$'\t' read -r TARGET _; do
        # Extract subdomain from the target
        SUBDOMAIN=$(echo "$TARGET" | cut -d'.' -f1)
        data+=$(cat <<EOL
        {
            "remark": "$SUBDOMAIN",
            "address": "$SUBDOMAIN.$DOMAIN",
            "port": 443,
            "sni": "",
            "host": "$REQUEST_HOST_SUBDOMAIN.$REQUEST_HOST_DOMAIN",
            "security": "tls",
            "alpn": "h2,http/1.1",
            "fingerprint": "random"
        },
EOL
)
    done <<< "$IRCF_DATA"
    # Remove the trailing comma
    echo "[${data%,}]"
}

# Wait for 15 seconds
countdown=15

while [ $countdown -gt 0 ]; do
    echo -ne "$countdown\033[0K\r"
    sleep 1
    ((countdown--))
done

ACCESS_TOKEN_RESPONSE=$(curl -s -X 'POST' \
  'http://localhost:8000/api/admin/token' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=&username=$MARZBAN_USER&password=$MARZBAN_PASS&scope=&client_id=&client_secret=")

# Check for errors in the response
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to retrieve access token."
    exit 1
fi

# Extract the access token from the response
ACCESS_TOKEN=$(echo "$ACCESS_TOKEN_RESPONSE" | jq -r '.access_token')

VLESS_IN_DATA=$(generate_inbound_data "vless-in")
VMESS_IN_DATA=$(generate_inbound_data "vmess-in")
TROJAN_IN_DATA=$(generate_inbound_data "trojan-in")

# Use the access token to create proxy hosts
curl --request PUT \
  --url "http://localhost:8000/api/hosts" \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header 'Content-Type: application/json' \
  --data "{
    \"vless-in\": $VLESS_IN_DATA,
    \"vmess-in\": $VMESS_IN_DATA,
    \"trojan-in\": $TROJAN_IN_DATA
}"

# Check for errors in the response
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to create proxy hosts."
    exit 1
fi

# Retrieve the information using the access token
RESPONSE=$(curl -s --request GET \
  --url "http://localhost:8000/api/hosts" \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header 'Content-Type: application/json')


# Get the server's public IP
SERVER_IP=$(curl -s ifconfig.me)

# Check if curl was successful
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to retrieve server's public IP."
    exit 1
fi

# Get the server's public IP
SERVER_IP=$(curl -s ifconfig.me)

# Check if curl was successful
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to retrieve server's public IP."
    exit 1
fi
# Modify the port, address, and remark for keys starting with vless-reality or grpc-reality
MODIFIED_RESPONSE=$(echo "$RESPONSE" | jq --arg ip "$SERVER_IP" '
                       to_entries |
                       map(
                         if .key | startswith("vless-reality") then
                           .value[0].port = 443 |
                           .value[0].remark = (.key + " {USERNAME}")
                         elif .key | startswith("grpc-reality") then
                           .value[0].remark = (.key + " {USERNAME}")
                         else . end |
                         (.value[]? | select(.address == "{SERVER_IP}")) .address = $ip
                       ) |
                       from_entries')


# Use the access token to create proxy hosts
curl --request PUT \
  --url "http://localhost:8000/api/hosts" \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header 'Content-Type: application/json' \
  --data "$MODIFIED_RESPONSE"

# Check for errors in the response
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to create proxy hosts."
    exit 1
fi


clear
echo "All setup is successfully done!"
echo "You can now login to your Marzban control panel using: https://$MARZBAN_SUBDOMAIN.$MARZBAN_DOMAIN/dashboard"

