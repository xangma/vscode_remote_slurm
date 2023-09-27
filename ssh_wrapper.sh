#!/bin/bash

PARENTPID=$$
GPARENTPID=$(ps -o ppid= -p $PARENTPID)
#echo "ParentPID: $PARENTPID"
#echo "GParentPID: $GPARENTPID"

# Ensure SSH binary path is correct
SSH_BINARY="/opt/homebrew/bin/ssh"
SSH_CONFIG_FILE="$HOME/.ssh/ssh_config"

function extract_ssh_config {
  local host=$1
  REMOTE_USERNAME=$(ssh -G $host | awk '/^user / { print $2 }')
  HOSTNAME=$(ssh -G $host | awk '/^hostname / { print $2 }')
  REMOTE_COMMAND=$(ssh -G $host | awk '/^remotecommand / { $1=""; print $0 }')
  IDENTITYFILE=$(ssh -G $host | awk '/^identityfile / { print $2 }')
  JOB_NAME=$(echo "$REMOTE_COMMAND" | grep -oE -- '-J\s[a-zA-Z]+' | awk '{print $2}' )
}

function wait_for_job {
  local jobname=$1
  local delay=$2
  local max_attempts=$3
  local attempt=0
  
  while ((attempt < max_attempts)); do
    # Fetch the job ID and node for the running job with the given name
#    read -r jobid node < <(ssh -o ControlPath=~/.ssh/cm_socket_%r@%h-%p "$REMOTE_USERNAME@$HOSTNAME" squeue --name="$jobname" --states=R -h -O JobID,Nodelist | awk '{print $1, $2}')
    read -r jobid node < <(ssh -i $IDENTITYFILE "$REMOTE_USERNAME@$HOSTNAME" squeue --name="$jobname" --states=R -h -O JobID,Nodelist | awk '{print $1, $2}')
    
    if [[ -n "$jobid" && -n "$node" ]]; then
      echo "Job is running. JobID: $jobid, Node: $node"
      JOBID="$jobid"
      NODE="$node"
      break
    fi
    
    sleep "$delay"
    ((attempt++))
  done
  
  if ((attempt == max_attempts)); then
    echo "Job did not start running within the specified attempts. Exiting."
    exit 1
  fi
}

function setup_control_master {
  rm ~/.ssh/cm_socket_$REMOTE_USERNAME@$HOSTNAME-22
  $SSH_BINARY -fN -o ControlMaster=yes -o ControlPersist=yes -o ControlPath=~/.ssh/cm_socket_%r@%h-%p $REMOTE_USERNAME@$HOSTNAME
}

function cancel_existing_jobs {
#  $SSH_BINARY -o ControlPath=~/.ssh/cm_socket_%r@%h-%p $REMOTE_USERNAME@$HOSTNAME scancel --jobname $JOB_NAME
  $SSH_BINARY -q -i $IDENTITYFILE $REMOTE_USERNAME@$HOSTNAME scancel --jobname $JOB_NAME
}

function allocate_resources {
#  $SSH_BINARY -o ControlPath=~/.ssh/cm_socket_%r@%h-%p $REMOTE_USERNAME@$HOSTNAME $REMOTE_COMMAND
  { ALLOC_OUTPUT=$($SSH_BINARY -i $IDENTITYFILE $REMOTE_USERNAME@$HOSTNAME $REMOTE_COMMAND 2>&1 >&3 3>&-); } 3>&1
#  echo "Got alloc output: $ALLOC_OUTPUT"
  JOBID=$(echo $ALLOC_OUTPUT | grep -oE "Granted job allocation \d+" | awk '{print $NF}')
#  echo "Recieved JobID: $JOBID"
  NODE=$($SSH_BINARY -o ControlPath=~/.ssh/cm_socket_%r@%h-%p $REMOTE_USERNAME@$HOSTNAME squeue --job=$JOBID --states=R -h -O Nodelist,JobID | awk '{print $1}')
#  echo "Got node: $NODE"
}

if [[ "$1" == "-V" ]]; then
  # Execute the original ssh command for version check
  $SSH_BINARY "$@"
else

  tmpfile=$(mktemp)

    
  while read -t 1 line; do
        echo "$line" >> $tmpfile
  done

  # Extract the port number
  PORT=$(echo "$@" | grep -oE -- '-D\s[0-9]+' | awk '{print $2}' )
  
  # Extract the remote host
  REMOTE_HOST=$(echo "$@" | awk '{print $NF}')

  # Extract ssh config details
  extract_ssh_config $REMOTE_HOST

  # Setup Control Master
#  echo "# Setup Control Master"
#  setup_control_master

  cancel_existing_jobs

  # Allocate resources using slurm
  #echo "# Allocate resources using slurm"
  allocate_resources
 
  #wait_for_job "$JOB_NAME" 1 10

# Cleanup on exit
  trap 'rm -f "$tmpfile"' EXIT

  # Start ssh
  stdin_commands=$(sed "s/'/'\\\\''/g" "$tmpfile")

  exec $SSH_BINARY -v -T -A -i $IDENTITYFILE -D $PORT -o StrictHostKeyChecking=no -o ConnectTimeout=60 -J $REMOTE_USERNAME@$HOSTNAME $REMOTE_USERNAME@$NODE srun --overlap --jobid $JOBID /bin/bash -c "'$stdin_commands && exec /bin/bash --login'" 

fi
