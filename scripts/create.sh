#!/bin/sh
# set -eox pipefail

echo "[create.sh]"

# Couple of variables to make local testing simpler
termination_log="/dev/termination-log"
acorn_output="/run/secrets/output"

# Make sure this script only repply on an Acorn creation event
if [ "${ACORN_EVENT}" = "delete" ]; then
   echo "ACORN_EVENT must be [create,update], currently is [${ACORN_EVENT}]"
   exit 0
fi

render_service() {
  local CLUSTER_NAME=$1
  local CREATED_DB_ROOT_USER=$2
  local CREATED_DB_USER=$3
  local db_name=${DB_NAME}

  DB_ADDRESS=$(atlas cluster describe ${CLUSTER_NAME} -o json | jq -r .connectionStrings.standardSrv)
  DB_PROTO=$(echo $DB_ADDRESS | cut -d':' -f1)
  DB_HOST=$(echo $DB_ADDRESS | cut -d'/' -f3)
  echo "DB_ADDRESS: [${DB_ADDRESS}] / DB_PROTO:[${DB_PROTO}] / DB_HOST:[${DB_HOST}]"

  cat > ${acorn_output}<<EOF
  services: atlas: {
    address: "${DB_HOST}"
    default: true
    secrets: ["admin", "user"]
    ports: "27017"
    data: {
      proto: "${DB_PROTO}"
      dbName: "${db_name}"
    }
  }
  secrets: state: {
    data: {
      created_db_user: "${CREATED_DB_USER}"
      created_db_root_user: "${CREATED_DB_ROOT_USER}"
    }
}
EOF
}

disk_size_arg() {
  if [ -n "${DISK_SIZE_GB}" ]; then
    echo "diskSizeGB ${DISK_SIZE_GB}"
  fi
}

db_user_update() {
  res=$(atlas dbusers update $@)
  if [ $? -ne 0 ]; then
    echo $res
  fi
}

db_user_create() {
  res=$(atlas dbusers create "$@")
  if [ $? -ne 0 ]; then
    echo $res
  fi
}

db_user_exists() {
  res=$(atlas dbusers describe $1 2>&1 >/dev/null)
  if [ $? -ne 0 ]; then
    echo ${res} | tee ${termination_log}
    return 1
  fi
}

# Use uppercase values for TIER / PROVIDER / REGION in case user specified lowercase ones
TIER=$(echo $TIER | tr a-z A-Z)
PROVIDER=$(echo $PROVIDER | tr a-z A-Z)
REGION=$(echo $REGION | tr a-z A-Z)

# Check if cluster with that name already exit
atlas cluster get ${CLUSTER_NAME} 2>/dev/null
if [ $? -ne 0 ]; then
  echo "-> cluster ${CLUSTER_NAME} does not exist"

  disk_arg=$(disk_size_arg)

  # Create a cluster in the current project
  echo "-> about to create cluster ${CLUSTER_NAME} of type ${TIER} in ${PROVIDER} / ${REGION}"
  result=$(atlas cluster create ${CLUSTER_NAME} \
          --region $REGION --provider $PROVIDER \
          --tier $TIER --tag creator=acorn_service \
          --tag acornid=${ACORN_EXTERNAL_ID} \
          --mdbVersion $DB_VERSION --${disk_arg} 2>&1)

  # Make sure the cluster was created correctly
  if [ $? -ne 0 ]; then
    echo $result
    echo $result | tee ${termination_log}
    exit 1
  fi
  
  # Wait for Atlas to provide cluster's connection string
  echo "-> waiting for database address"
  while true; do
    DB_ADDRESS=$(atlas cluster describe ${CLUSTER_NAME} -o json | jq -r .connectionStrings.standardSrv)
    if [ "${DB_ADDRESS}" = "null" ]; then
        sleep 2
        echo "... retrying"
    else
      break
    fi
  done
else
  echo "-> cluster ${CLUSTER_NAME} already exist"

  if atlas cluster get ${CLUSTER_NAME} -o json 2>&1 | grep ${TIER} > /dev/null ; then
    echo "-> cluster ${CLUSTER_NAME} already has the correct tier"
  else
    echo "-> updating cluster ${CLUSTER_NAME} of type ${TIER} in ${PROVIDER} / ${REGION}"
    disk_arg=$(disk_size_arg)
    echo ${disk_arg}
    result=$(atlas cluster upgrade "${CLUSTER_NAME}" --tier ${TIER} \
             --tag creator=acorn_service \
             --mdbVersion $DB_VERSION \
             ${disk_arg} 2>&1)
    if [ $? -ne 0 ]; then
      echo $result
      echo $result | tee ${termination_log}
      exit 1
    fi
  fi
fi

# Allow database network access from current IP
echo "allowing connection from current IP address"
res=$(atlas accessList create --currentIp)
if [ $? -ne 0 ]; then
  echo $res
fi

# Handle users and keep track of the ones created
created_db_root_user=""
created_db_user=""

# Handle admin db user
# check in atlas if the user exists
if db_user_exists "${DB_ROOT_USER}"; then
  echo "-> user ${DB_ROOT_USER} already exist... updating"
  db_user_update "${DB_ROOT_USER}" --password "${DB_ROOT_PASS}" --role "dbAdmin@{DB_NAME},readWrite@${DB_NAME}"
else
  echo "-> creating user ${DB_ROOT_USER}"
  db_user_create --username "${DB_ROOT_USER}" --password "${DB_ROOT_PASS}" --role "dbAdmin@${DB_NAME},readWrite@${DB_NAME}"
  created_db_root_user=${DB_ROOT_USER}
fi

# handle db user
if db_user_exists "${DB_USER}"; then
  echo "-> user ${DB_USER} already exist... updating"
  db_user_update "${DB_USER}" --password "${DB_PASS}" --role "readWrite@${DB_NAME}"
else
  echo "-> creating user ${DB_USER}"
  db_user_create --username "${DB_USER}" --password "${DB_PASS}" --role "readWrite@${DB_NAME}"
  created_user=${DB_USER}
fi

render_service ${CLUSTER_NAME} ${created_db_root_user} ${created_db_user}
