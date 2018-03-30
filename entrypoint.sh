#!/bin/sh

if [ -n "${DEBUG}" ]; then
    set -x
    env
fi

if [ -z "${HOSTED_ZONE_ID}" -o -z "${DNS_NAME}" ]; then
    echo "HOSTED_ZONE_ID and DNS_NAME are required" >&2
    exit 2
fi

# Figure out how we're going to authenticate
if [ -f /root/.aws/credentials ]; then
    echo "Authenticating using /root/.aws/credentials"
elif [ -n "${AWS_ACCESS_KEY_ID}" -a -n "${AWS_SECRET_ACCESS_KEY}" ]; then
    echo "Authenticating using environment variables"
elif [ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}" ]; then
    echo "Authenticating using container credentials at ${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}"
    /usr/bin/curl -f http://169.254.170.2${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI} > /tmp/credentials.json || exit 7
    export AWS_ACCESS_KEY_ID="$(cat /tmp/credentials.json | jq -r .AccessKeyId)"
    export AWS_SECRET_ACCESS_KEY="$(cat /tmp/credentials.json | jq -r .SecretAccessKey)"
elif [ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI}" ]; then
    echo "Authenticating using container credentials at ${AWS_CONTAINER_CREDENTIALS_FULL_URI}"
    /usr/bin/curl -f ${AWS_CONTAINER_CREDENTIALS_FULL_URI} > /tmp/credentials.json || exit 8
    export AWS_ACCESS_KEY_ID="$(cat /tmp/credentials.json | jq -r .AccessKeyId)"
    export AWS_SECRET_ACCESS_KEY="$(cat /tmp/credentials.json | jq -r .SecretAccessKey)"
else
    echo "Authentication method unknown"
fi

# Get all of the possible IP addresses
ip -o addr show | grep -v 'loopback\|scope host lo' | grep -oE 'inet6?\s+[^\s/]+' | cut -d ' ' -f 2 > /tmp/ips.txt

# Filter by CIDR and pick the first one
[ -n "${ADDRESS_CIDR}" ] && grepcidr -e ${ADDRESS_CIDR} /tmp/ips.txt >> /tmp/matched.txt
[ -n "${ADDRESS_CIDR6}" ] && grepcidr -e ${ADDRESS_CIDR6} /tmp/ips.txt >> /tmp/matched.txt
ADDR="$(head -n 1 /tmp/matched.txt)"

if [ -z "${ADDR}" ]; then
    echo "No IP addresses match ${ADDRESS_CIDR} ${ADDRESS_CIDR6}" >&2
    echo "" >&2
    echo "IP address candidates:" >&2
    cat /tmp/ips.txt >&2

    exit 3
fi

echo "Found matching address ${ADDR}"

function existing_addrs {
    aws --output json route53 list-resource-record-sets --hosted-zone-id=${HOSTED_ZONE_ID} > /tmp/recordsets.json || exit 6
    cat /tmp/recordsets.json | jq -c ".ResourceRecordSets | .[] | select(.Name == \"${DNS_NAME}.${ZONE_NAME}\") | .ResourceRecords" > /tmp/existing_addrs.txt

    [ -s /tmp/existing_addrs.txt ] || echo '[]' > /tmp/existing_addrs.txt
}

function deregister {
    echo "Caught exit signal, checking if we need to unregister ${ADDR}"

    [ -f /tmp/registered.txt ] || return
    existing_addrs
    ADDRS="$(jq -c ". - [{\"Value\":\"${ADDR}\"}] | unique_by(.Value)" /tmp/existing_addrs.txt)"
    eval echo "$(sed 's/"/\\"/g' /upsert.json | tr -s [:space:] ' ')" > /tmp/unregister.json

    echo "Unregistering ${ADDR} from ${DNS_NAME}.${ZONE_NAME}"
    cat /tmp/unregister.json
    aws --output json ${DEBUG:+--debug} route53 change-resource-record-sets --cli-input-json file:///tmp/unregister.json
}
trap deregister EXIT

ZONE_NAME="$(aws --output json route53 get-hosted-zone --id=${HOSTED_ZONE_ID}  | jq -r .HostedZone.Name)"
if [ -z "${ZONE_NAME}" ]; then
    echo "Unable to get hosted zone name from AWS" >&2
    exit 5
fi

existing_addrs
ADDRS="$(jq -c ". + [{\"Value\":\"${ADDR}\"}] | unique_by(.Value)" /tmp/existing_addrs.txt)"

eval echo "$(sed 's/"/\\"/g' /upsert.json | tr -s [:space:] ' ')" > /tmp/register.json

echo "Registering ${ADDR} with ${DNS_NAME}.${ZONE_NAME}"
cat /tmp/register.json
aws --output json ${DEBUG:+--debug} route53 change-resource-record-sets --cli-input-json file:///tmp/register.json || exit 6
touch /tmp/registered.txt

# Wait forever, only exit on signal
echo "Waiting for signal to exit"
mkfifo /tmp/waiter
read SIGNAL < /tmp/waiter
