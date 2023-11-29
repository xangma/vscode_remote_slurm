#!/bin/bash

SSH_BINARY=$(which ssh)
SSH_CONFIG_FILE="$HOME/.ssh/ssh_config"
DEBUGMODE=1
function extract_prefix_and_number {
    echo "$1" | sed -n -e '/\[/!p' -e 's/\([a-z]*\)\[\([0-9]*\)[,-].*/\1\2/p'
}

function extract_ssh_config {
    local host=$1
    REMOTE_USERNAME=$($SSH_BINARY -G $host | awk '/^user / { print $2 }')
    HOSTNAME=$($SSH_BINARY -G $host | awk '/^hostname / { print $2 }')
    REMOTE_COMMAND=$($SSH_BINARY -G $host | awk '/^remotecommand / { $1=""; print $0 }')
    IDENTITYFILE=$($SSH_BINARY -G $host | awk '/^identityfile / { print $2 }')
    JOB_NAME=$(echo "$REMOTE_COMMAND" | grep -oE -- '\-J\s+.*[^\s]+' | awk '{print $2}' )
    if [[ $DEBUGMODE == 1 ]]; then
        echo "REMOTE_USERNAME: $REMOTE_USERNAME"
        echo "HOSTNAME: $HOSTNAME"
        echo "REMOTE_COMMAND: $REMOTE_COMMAND"
        echo "IDENTITYFILE: $IDENTITYFILE"
        echo "JOB_NAME: $JOB_NAME"
    fi
}

function cancel_existing_jobs {
    if [[ $DEBUGMODE == 1 ]]; then
        echo "Cancelling existing jobs"
    fi
    $SSH_BINARY -q -i $IDENTITYFILE $REMOTE_USERNAME@$HOSTNAME scancel --jobname $JOB_NAME
    if [[ $DEBUGMODE == 1 ]]; then
        echo "Cancelled existing jobs"
    fi
}

function allocate_resources {
    # Allocate resources using slurm
    # The end part that looks like someone mashed their keyboard came from this SO post:
    # https://unix.stackexchange.com/questions/474177/how-to-redirect-stderr-in-a-variable-but-keep-stdout-in-the-console

    if [[ $DEBUGMODE == 1 ]]; then
        echo "Allocating resources..."
    fi
    { ALLOC_OUTPUT=$($SSH_BINARY -i $IDENTITYFILE $REMOTE_USERNAME@$HOSTNAME $REMOTE_COMMAND 2>&1 >&3 3>&-); } 3>&1
    
    if [[ $DEBUGMODE == 1 ]]; then
        echo $ALLOC_OUTPUT
    fi

    # Extract the job id
    JOBID=$(echo $ALLOC_OUTPUT | grep -oE "Granted job allocation [0-9]+" | awk '{print $NF}')
    if [[ $DEBUGMODE == 1 ]]; then
        echo "JOBID: $JOBID"
    fi
    # Extract the node name
    NODE=$($SSH_BINARY $REMOTE_USERNAME@$HOSTNAME squeue --job=$JOBID --states=R -h -O Nodelist,JobID | awk '{print $1}')
    NODE=$(extract_prefix_and_number $NODE)
    if [[ $DEBUGMODE == 1 ]]; then
        echo "NODE: $NODE"
    fi
}

if [[ "$1" == "-V" ]]; then
    # Execute the original ssh command for version check
    $SSH_BINARY "$@"
else
    # vscode will be running ssh with these args:
    # "-v -T -D port -o ConnectTimeout=60 remotehost"

    # Extract the port number from vscode's ssh args.
    PORT=$(echo "$@" | grep -oE -- '-D\s[0-9]+' | awk '{print $2}' )

    if [[ $DEBUGMODE == 1 ]]; then
        echo "PORT: $PORT"
    fi

    # Extract the remote host too
    REMOTE_HOST=$(echo "$@" | awk '{print $NF}')

    if [[ $DEBUGMODE == 1 ]]; then
        echo "REMOTE_HOST: $REMOTE_HOST"
    fi

    # Use the remote host to extract the ssh config
    extract_ssh_config $REMOTE_HOST

    if [[ "$REMOTE_COMMAND" == *"salloc"* ]]; then

        # Read stdin into a temp file
        tmpfile=$(mktemp)

        while read -t 1 line; do
            echo "$line" >> $tmpfile
        done

        # Cancel any existing jobs
        cancel_existing_jobs

        # Allocate resources using slurm using salloc (currently defined in ssh_config RemoteCommand - e.g. RemoteCommand salloc --no-shell -n 1 -c 4 -J vscode --time=1:00:00)
        allocate_resources

        # Cleanup on exit
        # TODO: learn more about this so it can cancel on exit etc.
        trap 'rm -f "$tmpfile"; cancel_existing_jobs' EXIT

        # Format the commands vscode wanted to run.
        stdin_commands=$(sed "s/'/'\\\\''/g" "$tmpfile")

        # Run the commands on the remote host
        if [[ $DEBUGMODE == 1 ]]; then
            echo "Running commands on remote host"
            echo $stdin_commands
        fi
        $SSH_BINARY -v -T -A -i $IDENTITYFILE -D $PORT -o StrictHostKeyChecking=no -o ConnectTimeout=60 -J $REMOTE_USERNAME@$HOSTNAME $REMOTE_USERNAME@$NODE srun --overlap --jobid $JOBID /bin/bash -c "'$stdin_commands && exec /bin/bash --login'" 
    else
        # Execute the SSH command normally without resource allocation
        $SSH_BINARY "$@"
    fi
fi
