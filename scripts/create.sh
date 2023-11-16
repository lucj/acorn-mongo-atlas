#!/bin/sh
# set -eo pipefail

echo "[create.sh]"

# Make sure this script only replies to an Acorn creation event
if [ "${ACORN_EVENT}" != "create" ]; then
   echo "ACORN_EVENT must be [create], currently is [${ACORN_EVENT}]"
   exit 0
fi

# Check if cluster with that name already exits
res=$(atlas cluster list -o json | jq -r --arg cluster_name "$CLUSTER_NAME" '
  if .results then
    .results[] | select(.name == $cluster_name)
  else
    empty
  end
')
if [ "$res" != "" ]; then
  echo "cluster ${CLUSTER_NAME} already exists" | tee /dev/termination-log
  exit 1
fi 
echo "cluster ${CLUSTER_NAME} does not exist"

# Create a cluster in the current project
echo "about to create cluster ${CLUSTER_NAME} of type ${TIER} in ${PROVIDER} / ${REGION}"
res=$(atlas cluster create ${CLUSTER_NAME} --region $REGION --provider $PROVIDER --tier $TIER --tag acornid=${ACORN_EXTERNAL_ID} --mdbVersion $DB_VERSION 2>&1)

# Make sure the cluster was created correctly
if [ $? -ne 0 ]; then
  echo $res | tee /dev/termination-log
  exit 1
fi

# Wait for Atlas to provide cluster's connection string
echo "waiting for database address"
while true; do
  DB_ADDRESS=$(atlas cluster describe ${CLUSTER_NAME} -o json | jq -r .connectionStrings.standardSrv)
  if [ "${DB_ADDRESS}" = "null" ]; then
      sleep 2
      echo "... retrying"
  else
    break
  fi
done

# Allow database network access from current IP
echo "allowing connection from current IP address"
res=$(atlas accessList create --currentIp)
if [ $? -ne 0 ]; then
  echo $res
fi

# Create db user
echo "creating a database user"
CREATED_DB_USER=""
res=$(atlas dbusers create --username ${DB_USER} --password ${DB_PASS} --role readWrite@${DB_NAME})
if [ $? -ne 0 ]; then
  echo $res
  echo "database user not created"
else
  # Keep track of created user
  # Used in the deletion step to prevent deletion of a pre-existing user
  echo "database user created"
  CREATED_DB_USER=${DB_USER}
fi

# Extract proto and host from address returned
DB_PROTO=$(echo $DB_ADDRESS | cut -d':' -f1)
DB_HOST=$(echo $DB_ADDRESS | cut -d'/' -f3)
echo "connection string: [${DB_PROTO}://${DB_USER}:${DB_PASS}@${DB_HOST}]"

cat > /run/secrets/output<<EOF
services: atlas: {
  address: "${DB_HOST}"
  secrets: ["user"]
  ports: "27017"
  data: {
    proto: "${DB_PROTO}"
    dbName: "${DB_NAME}"
  }
}
secrets: state: {
  data: {
    created_user: "${CREATED_DB_USER}"
  }
}
EOF