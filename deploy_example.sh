#!/bin/bash

# Configuración
JENKINS_URL="http://jenkins.example.com"
JENKINS_JOB="nombre_del_job"
JENKINS_USER="usuario"
JENKINS_API_TOKEN="token_o_password"
JENKINS_TOKEN="token_de_disparo_del_job"
JENKINS_MESSAGE="Deploying application"

# Verificar si hay commits pendientes
COMMITS_AHEAD=$(git rev-list --count origin/master..HEAD)

if [ "$COMMITS_AHEAD" -eq 0 ]; then
  echo "✔ No hay commits nuevos. No se hace push ni se lanza Jenkins."
  exit 0
fi

# Paso 1: Obtener el crumb CSRF de Jenkins
echo "🤖 Obteniendo crumb de Jenkins..."
CRUMB_JSON=$(curl -s -u "$JENKINS_USER:$JENKINS_API_TOKEN" "$JENKINS_URL/crumbIssuer/api/json")

CRUMB=$(echo "$CRUMB_JSON" | jq -r .crumb)
CRUMB_FIELD=$(echo "$CRUMB_JSON" | jq -r .crumbRequestField)
if [ -z "$CRUMB" ]; then
  echo "❌ No se pudo obtener el crumb. Abortando."
  exit 1
fi

echo "✅ Crumb obtenido."

# Paso 2: Realizar git push
echo "📤 Haciendo push a origin/master..."
if git push origin master; then
  echo "✅ Git push exitoso."
else
  echo "❌ Git push falló. Abortando despliegue."
  exit 1
fi

# Paso 3: Ejecutar el job en Jenkins
# Obtener el número del último build antes de lanzar uno nuevo
echo "🔎 Obteniendo número del último build..."
LAST_BUILD=$(curl -s -u "$JENKINS_USER:$JENKINS_API_TOKEN" "$JENKINS_URL/job/$JENKINS_JOB/lastBuild/api/json" | jq -r '.number')

if [ -z "$LAST_BUILD" ] || [ "$LAST_BUILD" == "null" ]; then
  echo "❌ No se pudo obtener el número del último build. Abortando."
  exit 1
fi

echo "🚀 Lanzando build en Jenkins..."

# Reintentos para lanzar el job
MAX_RETRIES=3
RETRY_DELAY=5
RETRIES=0
SUCCESS=0

JENKINS_MESSAGE_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('Deploying application'))")
FINAL_URL="$JENKINS_URL/job/$JENKINS_JOB/buildWithParameters?token=$JENKINS_TOKEN&cause=$JENKINS_MESSAGE_ENCODED"
echo "URL generada: $FINAL_URL"

while [ $RETRIES -lt $MAX_RETRIES ]; do
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$FINAL_URL" \
    -u "$JENKINS_USER:$JENKINS_API_TOKEN" \
    -H "$CRUMB_FIELD:$CRUMB")

  if [ "$RESPONSE" -eq 201 ]; then
    SUCCESS=1
    break
  else
    echo "❌ Falló el intento de lanzar el job. Reintentando en $RETRY_DELAY segundos..."
    ((RETRIES++))
    sleep $RETRY_DELAY
  fi
done

if [ "$SUCCESS" -eq 0 ]; then
  echo "❌ No se pudo lanzar el job después de $MAX_RETRIES intentos. Abortando despliegue."
  exit 1
fi

# Paso 4: Consultar el estado del nuevo build
# Espera unos segundos para asegurar que el nuevo build se haya iniciado
echo "⏳ Esperando a que se lance el nuevo build..."
sleep 20

# Obtener el nuevo número de build
NEW_BUILD=$(curl -s -u "$JENKINS_USER:$JENKINS_API_TOKEN" "$JENKINS_URL/job/$JENKINS_JOB/lastBuild/api/json" | jq -r '.number')

if [ "$NEW_BUILD" -le "$LAST_BUILD" ]; then
  echo "❌ No se detectó un nuevo build. Algo falló."
  exit 1
fi

# Consultar estado del nuevo build
echo "🔍 Estado del build #$NEW_BUILD:"
BUILD_STATUS=$(curl -s -u "$JENKINS_USER:$JENKINS_API_TOKEN" "$JENKINS_URL/job/$JENKINS_JOB/$NEW_BUILD/api/json" | jq -r '.result')

if [ "$BUILD_STATUS" = "null" ]; then
  echo "🕒 Build #$NEW_BUILD en progreso..."
else
  echo "✅ Resultado: $BUILD_STATUS"
fi