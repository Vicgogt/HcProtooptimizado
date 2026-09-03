cat > hcr-menu.sh << 'EOF'
#!/bin/bash
# MENÚ HCR CUSTOM - Para Vicgogt/hcr-server

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'

SERVICE_NAME="hcr-server"
BIN_DIR="/root/hcr-server"
CONFIG_FILE="/etc/hcr/hcr.conf"

# Cargar configuración o valores por defecto
if [ -f "$CONFIG_FILE" ]; then
    source $CONFIG_FILE
else
    HCR_PORT="8080"
    REDIR_PORT="22"
    MAX_FRAME="264"
    POLL_TIMEOUT="29s"
    SSL_MODE="auto"
fi

guardar_config() {
    mkdir -p /etc/hcr
    cat > $CONFIG_FILE << EOL
HCR_PORT=$HCR_PORT
REDIR_PORT=$REDIR_PORT
MAX_FRAME=$MAX_FRAME
POLL_TIMEOUT=$POLL_TIMEOUT
SSL_MODE=$SSL_MODE
EOL
}

actualizar_servicio() {
    systemctl stop $SERVICE_NAME 2>/dev/null

    cat > /etc/systemd/system/$SERVICE_NAME.service << EOL
[Unit]
Description=HCR Server (Custom)
After=network.target

[Service]
Type=exec
User=root
WorkingDirectory=$BIN_DIR
ExecStart=$BIN_DIR/hcr-server --listen :$HCR_PORT --target 127.0.0.1:$REDIR_PORT --transport $SSL_MODE --max-download-frame $MAX_FRAME --download-poll-timeout $POLL_TIMEOUT
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME
    echo -e "${G}✅ Servicio actualizado y reiniciado${N}"
}

while true; do
    clear
    echo -e "${C}════════════════════════════════════════${N}"
    echo -e "${W}      ADM HCR CUSTOM NETSYS${N}"
    echo -e "${C}════════════════════════════════════════${N}"
    echo ""
    echo -e " ${Y}[1]${N} ${W}PUERTO HCR:${N} ${C}$HCR_PORT${N}"
    echo -e " ${Y}[2]${N} ${W}PUERTO REDIRECCION:${N} ${C}$REDIR_PORT${N}"
    echo -e " ${Y}[3]${N} ${W}MAX DOWNLOAD FRAME:${N} ${C}$MAX_FRAME${N}"
    echo -e " ${Y}[4]${N} ${W}DOWNLOAD POLL TIMEOUT:${N} ${C}$POLL_TIMEOUT${N}"
    echo -e " ${Y}[5]${N} ${W}MODO SSL/TLS:${N} ${C}[$SSL_MODE]${N}"
    echo -e " ${Y}[6]${N} ${W}ESTADO DEL SERVICIO${N}"
    echo -e " ${Y}[7]${N} ${W}REINICIAR SERVICIO${N}"
    echo -e " ${Y}[8]${N} ${W}INICIAR/PARAR SERVICIO${N}"
    echo ""
    echo -e " ${R}[0]${N} ${W}Volver${N}    ${R}[9]${N} ${W}DESINSTALAR${N}"
    echo ""
    read -p "Ingresa una Opcion: " opcion

    case $opcion in
        1)
            read -p "Nuevo puerto HCR (1-65535): " new
            if [[ "$new" =~ ^[0-9]+$ ]] && [ "$new" -ge 1 ] && [ "$new" -le 65535 ]; then
                HCR_PORT=$new
                guardar_config
                actualizar_servicio
            else
                echo -e "${R}❌ Puerto inválido${N}"
            fi
            read -p "Presiona Enter..."
            ;;
        2)
            read -p "Nuevo puerto de redirección (1-65535): " new
            if [[ "$new" =~ ^[0-9]+$ ]] && [ "$new" -ge 1 ] && [ "$new" -le 65535 ]; then
                REDIR_PORT=$new
                guardar_config
                actualizar_servicio
            else
                echo -e "${R}❌ Puerto inválido${N}"
            fi
            read -p "Presiona Enter..."
            ;;
        3)
            read -p "Nuevo MAX DOWNLOAD FRAME (bytes, mínimo 64): " new
            if [[ "$new" =~ ^[0-9]+$ ]] && [ "$new" -ge 64 ]; then
                MAX_FRAME=$new
                guardar_config
                actualizar_servicio
            else
                echo -e "${R}❌ Valor inválido (mínimo 64)${N}"
            fi
            read -p "Presiona Enter..."
            ;;
        4)
            read -p "Nuevo DOWNLOAD POLL TIMEOUT (ej: 5s, 10s, 30s, 1m): " new
            if [[ "$new" =~ ^[0-9]+[smh]?$ ]]; then
                POLL_TIMEOUT=$new
                guardar_config
                actualizar_servicio
            else
                echo -e "${R}❌ Formato inválido (ej: 5s, 10s, 30s, 1m)${N}"
            fi
            read -p "Presiona Enter..."
            ;;
        5)
            if [ "$SSL_MODE" = "OFF" ] || [ "$SSL_MODE" = "plain" ]; then
                SSL_MODE="auto"
                echo -e "${G}✅ SSL activado (modo auto)${N}"
            else
                SSL_MODE="plain"
                echo -e "${Y}⚠️ SSL desactivado (modo plain)${N}"
            fi
            guardar_config
            actualizar_servicio
            read -p "Presiona Enter..."
            ;;
        6)
            echo -e "${C}📊 Estado del servicio:${N}"
            systemctl status $SERVICE_NAME --no-pager 2>/dev/null || echo -e "${R}❌ Servicio no encontrado${N}"
            read -p "Presiona Enter..."
            ;;
        7)
            systemctl restart $SERVICE_NAME
            echo -e "${G}✅ Servicio reiniciado${N}"
            read -p "Presiona Enter..."
            ;;
        8)
            if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
                systemctl stop $SERVICE_NAME
                echo -e "${Y}⏹ Servicio detenido${N}"
            else
                systemctl start $SERVICE_NAME
                echo -e "${G}▶️ Servicio iniciado${N}"
            fi
            read -p "Presiona Enter..."
            ;;
        9)
            echo -e "${R}⚠️ DESINSTALANDO HCR...${N}"
            systemctl stop $SERVICE_NAME 2>/dev/null
            systemctl disable $SERVICE_NAME 2>/dev/null
            rm -f /etc/systemd/system/$SERVICE_NAME.service
            rm -rf /etc/hcr
            systemctl daemon-reload
            echo -e "${G}✅ HCR desinstalado${N}"
            echo -e "${Y}Los archivos en $BIN_DIR se mantienen${N}"
            exit 0
            ;;
        0)
            echo -e "${G}👋 Saliendo...${N}"
            exit 0
            ;;
        *)
            echo -e "${R}❌ Opción inválida${N}"
            read -p "Presiona Enter..."
            ;;
    esac
done
EOF

chmod +x hcr-menu.sh
