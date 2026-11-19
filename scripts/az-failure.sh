#!/usr/bin/env bash
# Simulates loss of the AZ that hosts the Aurora writer, while a student keeps autosaving.
#   scripts/az-failure.sh failover    # force Aurora writer to the other AZ (what happens when AZ-a dies)
#   scripts/az-failure.sh blackhole   # additionally deny all traffic in AZ-a subnets with a NACL
#   scripts/az-failure.sh restore     # undo the blackhole
set -euo pipefail
OUT=infra; PASS='Demo-Passw0rd-2026'
SITE=$(terraform -chdir=$OUT output -raw site_url)
CLIENT=$(terraform -chdir=$OUT output -raw user_pool_client_id)
CLUSTER=$(terraform -chdir=$OUT output -raw db_cluster_id)
VPC=$(terraform -chdir=$OUT output -raw vpc_id)
STATE=/tmp/az-nacl-state.txt

writer_az() { aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier' --output text \
  | xargs -I{} aws rds describe-db-instances --db-instance-identifier {} --query 'DBInstances[0].AvailabilityZone' --output text; }

case "${1:-failover}" in
failover)
  TOKEN=$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id "$CLIENT" \
    --auth-parameters USERNAME=student@example.com,PASSWORD="$PASS" --query AuthenticationResult.IdToken --output text)
  EXAM=${EXAM_ID:-1}
  curl -sS -X POST "$SITE/api/exams/$EXAM/start" -H "authorization: $TOKEN" >/dev/null
  echo "writer AZ before: $(writer_az)"
  ( for i in $(seq 1 90); do   # one autosave every 2 s for 3 minutes
      code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$SITE/api/exams/$EXAM/answers" -H "authorization: $TOKEN" \
        -H 'content-type: application/json' -d "{\"answers\":{\"q1\":1,\"q2\":\"autosave $i\"}}")
      echo "$(date +%T) autosave #$i -> HTTP $code"; sleep 2; done ) | tee evidence/az-failure-autosave.log &
  sleep 10; echo "$(date +%T) >>> FAILOVER START"; aws rds failover-db-cluster --db-cluster-identifier "$CLUSTER" >/dev/null
  wait; echo "writer AZ after: $(writer_az)"
  echo "Expect a few 5xx/409 (browser retries) for ~30-60 s, then HTTP 200 again. Log: evidence/az-failure-autosave.log" ;;
blackhole)
  AZ=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)
  SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=availability-zone,Values="$AZ" --query 'Subnets[].SubnetId' --output text)
  NACL=$(aws ec2 create-network-acl --vpc-id "$VPC" --query NetworkAcl.NetworkAclId --output text)  # deny-all by default
  : > $STATE; echo "NACL $NACL" >> $STATE
  for s in $SUBNETS; do
    assoc=$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values="$s" --query "NetworkAcls[0].Associations[?SubnetId=='$s'].NetworkAclAssociationId" --output text)
    old=$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values="$s" --query 'NetworkAcls[0].NetworkAclId' --output text)
    aws ec2 replace-network-acl-association --association-id "$assoc" --network-acl-id "$NACL" >/dev/null
    echo "SUBNET $s $old" >> $STATE
  done
  echo "AZ $AZ blackholed. Re-run the demo/autosave loop: traffic must keep working via the other AZ. Undo with: $0 restore" ;;
restore)
  NACL=$(awk '$1=="NACL"{print $2}' $STATE)
  awk '$1=="SUBNET"{print $2, $3}' $STATE | while read -r s old; do
    assoc=$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values="$s" --query "NetworkAcls[0].Associations[?SubnetId=='$s'].NetworkAclAssociationId" --output text)
    aws ec2 replace-network-acl-association --association-id "$assoc" --network-acl-id "$old" >/dev/null
  done
  aws ec2 delete-network-acl --network-acl-id "$NACL"; echo restored ;;
esac
