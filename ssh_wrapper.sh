#!/bin/bash

DEBUGMODE=1
config_file=".ssh/config"
SSH_BINARY=$(which ssh)
SSH_CONFIG_FILE="$HOME/$config_file"

SCANCEL_TIMEOUT=60

if [[ $DEBUGMODE == 1 ]]; then
    echo "SSH_BINARY: $SSH_BINARY"
    echo "SSH_CONFIG_FILE: $SSH_CONFIG_FILE"
fi

function extract_prefix_and_number {
    # Extract the prefix and number from a string
    # Examples:
    # input: "node[1-2,4-5]" output: "node1"
    # input: "node1" output: "node1"
    echo "$1" | sed -n -e '/\[/!p' -e 's/\([a-z]*\)\[\([0-9]*\)[,-].*/\1\2/p'
}

function extract_ssh_config {
    # Extract certain values from the ssh config for the remote host
    local host=$1
    REMOTE_USERNAME=$($SSH_BINARY -F $SSH_CONFIG_FILE -G $host | awk '/^user / { print $2 }')
    HOSTNAME=$($SSH_BINARY -F $SSH_CONFIG_FILE -G $host | awk '/^hostname / { print $2 }')
    REMOTE_COMMAND=$($SSH_BINARY -F $SSH_CONFIG_FILE -G $host | awk '/^remotecommand / { $1=""; print $0 }')
    IDENTITYFILE=$($SSH_BINARY -F $SSH_CONFIG_FILE -G $host | awk '/^identityfile / { print $2 }')
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
    cmd="squeue -h -u $REMOTE_USERNAME --format=\"%.18i %.50j\" | grep -E $JOB_NAME | awk '{if(\$NR>1)print \$1}' | xargs -r scancel"
    if [[ $DEBUGMODE == 1 ]]; then
        echo "Cancelling existing jobs with $JOB_NAME with command $cmd"
    fi
    $SSH_BINARY -F $SSH_CONFIG_FILE -q -i $IDENTITYFILE $REMOTE_USERNAME@$HOSTNAME $cmd
    if [[ $DEBUGMODE == 1 ]]; then
        echo "Cancelled existing jobs"
    fi
}

function allocate_resources {
    # Allocate resources using slurm using salloc (currently defined in ssh_config RemoteCommand - e.g. RemoteCommand salloc --no-shell -n 1 -c 4 -J vscode --time=1:00:00)

    if [[ $DEBUGMODE == 1 ]]; then
        echo "Allocating resources..."
    fi

    # Extend the remote command to check for the job first, if it doesn't exist, reserve the resources, 
    # then print the allocated node name to stderr after the salloc command completes and a node is assigned. 
    # Example: NODE: node1
    REMOTE_COMMAND="FOUND_JOB=\$(squeue --user=$REMOTE_USERNAME --name=$JOB_NAME --states=R,PD -h -O JobID) && \
        if [[ ! -z \"\$FOUND_JOB\" ]]; then \
            >&2 echo \"Job $JOB_NAME already exists. Skipping resource reservation. Granted job allocation \$FOUND_JOB\"; \
        else \
            $REMOTE_COMMAND; \
        fi; >&2 echo \"NODE: \$(squeue --user=$REMOTE_USERNAME --name=$JOB_NAME --states=R -h -O Nodelist | awk '{print \$1}')\""

    # I think the salloc command prints to stderr, so this is a trick to get the salloc output into a bash variable, and print it to the terminal. 
    # There is probably a better way to do this.
    # It redirects stderr to stdout and then redirects stdout to a file descriptor 3, then runs the command, 
    # then redirects file descriptor 3 to the original stdout and reads the file descriptor 3 into the ALLOC_OUTPUT variable.
    # 
    # The end part that looks like someone mashed their keyboard came from this SO post:
    # https://unix.stackexchange.com/questions/474177/how-to-redirect-stderr-in-a-variable-but-keep-stdout-in-the-console

    { ALLOC_OUTPUT=$($SSH_BINARY -F $SSH_CONFIG_FILE -o StrictHostKeyChecking=no -i $IDENTITYFILE $REMOTE_USERNAME@$HOSTNAME $REMOTE_COMMAND 2>&1 >&3 3>&-); } 3>&1
    
    # if [[ $DEBUGMODE == 1 ]]; then
    #     echo "Modified REMOTE_COMMAND: $REMOTE_COMMAND"
    #     echo "Here's ALLOC_OUTPUT: $ALLOC_OUTPUT"
    # fi

    # Extract the job id
    JOBID=$(echo $ALLOC_OUTPUT | grep -oE "Granted job allocation [0-9]+" | awk '{print $NF}')
    if [[ $DEBUGMODE == 1 ]]; then
        echo "JOBID: $JOBID"
    fi
    # Extract the node name
    NODE=$(echo $ALLOC_OUTPUT | grep -oE "NODE: [a-zA-Z0-9]+" | awk '{print $NF}')
    NODE=$(extract_prefix_and_number $NODE)
    if [[ $DEBUGMODE == 1 ]]; then
        echo "NODE: $NODE"
    fi
}

if [ "$1" = "-V" ]; then
    # Execute the original ssh command for version check
    $SSH_BINARY -F $SSH_CONFIG_FILE "$@"
else
    # vscode will be running ssh with these args:
    # "-v -T -D port -o ConnectTimeout=60 remotehost"
    
    # Extract the port number from vscode's ssh args.
    PORT=$(echo "$@" | grep -oE -- '-D\s[0-9]+' | awk '{print $2}' )

    if [[ $DEBUGMODE == 1 ]]; then
        echo "PORT: $PORT"
    fi

    # Extract the remote host too
    REMOTE_HOST=$(echo "$@" | awk '{print $(NF)}')
    if [ $REMOTE_HOST = "bash" ]; then
        REMOTE_HOST=$(echo "$@" | awk '{print $(NF-1)}');
    fi

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

        stdin_commands=$(sed "s/'/'\\\\''/g" "$tmpfile")

        # Cancel any existing jobs
        # cancel_existing_jobs

        # Allocate resources using slurm using salloc (currently defined in ssh_config RemoteCommand - e.g. RemoteCommand salloc --no-shell -n 1 -c 4 -J vscode --time=1:00:00)
        allocate_resources

        # Run the commands on the remote host
        # if [[ $DEBUGMODE == 1 ]]; then
        #     echo "Running commands on remote host"
        #     echo $stdin_commands
        # fi

        # This is an ssh command that proxy jumps through the remote host to the allocated node and runs srun with:
        # - the --overlap flag which allows job steps to share all resources, 
        # - the --jobid flag which specifies the job id to which the step is associated with,
        # and srun runs bash in the job (required for vscode to talk to the remote) that: 
        # - gets the pid of the ssh command from the SSH_AUTH_SOCK environment variable,
        # - kills any previous watcher processes,
        # - runs a watcher loop that sleeps for 1 second and checks if the ssh command is still running,
        # - and if the ssh command is no longer running, it scancels the job and exits.
        # The disown -h command is used to disown the loop so that it doesn't get killed when the ssh command exits.
        # The $stdin_commands are then executed and the shell is replaced with a new (login) shell using exec.

        $SSH_BINARY -F $SSH_CONFIG_FILE -T -A -i $IDENTITYFILE -D $PORT \
        -o StrictHostKeyChecking=no -o ConnectTimeout=120 \
        -J $REMOTE_USERNAME@$HOSTNAME $REMOTE_USERNAME@$NODE \
        srun --overlap --jobid $JOBID /bin/bash -c \
        "'$stdin_commands && \
        ssh_pid=\$(echo \$SSH_AUTH_SOCK | cut -d\".\" -f2); \
        pkill -f .WATCHER_VSC_$REMOTE_USERNAME.; \
        (echo \"WATCHER_VSC_$REMOTE_USERNAME: \$\$\"; \
        echo \"watching ppid: \$ssh_pid\"; \
        while kill -0 \$ssh_pid 2>/dev/null; do sleep 1; done; \
        sleep $SCANCEL_TIMEOUT && scancel $JOBID; exit 0) & disown -h && \
        exec /bin/bash --login'"

    else
        # Execute the SSH command normally without resource allocation
        if [[ $DEBUGMODE == 1 ]]; then
            echo "Executing SSH command normally"
            echo $SSH_BINARY -F $SSH_CONFIG_FILE "$@"
        fi
        $SSH_BINARY -F $SSH_CONFIG_FILE "$@"
    fi
fi
