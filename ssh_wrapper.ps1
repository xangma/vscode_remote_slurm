# Set-StrictMode -Version Latest

$SSH_BINARY = Get-Command ssh.exe | Select-Object -ExpandProperty Source
$SSH_CONFIG_FILE = Join-Path $HOME ".ssh\config"
$DEBUGMODE = $true
$SCANCEL_TIMEOUT = 300
# WATCHER_SETTING can set to either "socket" or "pid" to determine how to watch out for the ssh command to exit.
# Option: "socket" is the default and watches for the ssh connection to end by watching for the socket file to be deleted.
# Use "socket" when useLocalServer is set to true. This is because the ssh command is run by the local server and
# the socket file is deleted when the ssh command exits.
# Option "pid" uses the SSH_AUTH_SOCK environment variable to get the pid of the ssh connection to then send and scancel.
# Use "pid" when useLocalServer is set to false. This is because the ssh command exits on the remote server when you close the connection.
$WATCHER_SETTING = "socket"

Function Extract-Prefix-And-Number {
    Param ([string]$str)
    if ($NODE.Contains("-")) {
        $NODE = ($NODE -split "\[")[0]+($NODE -split "\[")[1].Split("-")[0]
    }
    return $NODE
}

Function Extract-SSH-Config {
    Param ([string]$remoteHost)
    # Initialize global variables to ensure they are set before being accessed
    $global:REMOTE_USERNAME = ""
    $global:HOSTNAME = ""
    $global:REMOTE_COMMAND = ""
    $global:IDENTITYFILE = ""
    $global:JOB_NAME = ""
    $global:REMOTE_USERNAME = & $SSH_BINARY -G $remoteHost | Select-String "^user " | ForEach-Object { $_ -replace "^user ", "" }
    $global:HOSTNAME = & $SSH_BINARY -G $remoteHost | Select-String "^hostname " | ForEach-Object { $_ -replace "^hostname ", "" }
    $global:REMOTE_COMMAND = & $SSH_BINARY -G $remoteHost | Select-String "^remotecommand " | ForEach-Object { $_ -replace "^remotecommand ", "" }
    $global:IDENTITYFILE = & $SSH_BINARY -G $remoteHost | Select-String "^identityfile " | ForEach-Object { $_ -replace "^identityfile ", "" }
    if ($null -ne $global:REMOTE_COMMAND -and $global:REMOTE_COMMAND.Contains("-J ")) {
        $global:JOB_NAME = ($global:REMOTE_COMMAND -split "-J ")[1].Split(" ")[0]
    }

    if ($DEBUGMODE) {
        Write-Host "REMOTE_USERNAME: $global:REMOTE_USERNAME"
        Write-Host "HOSTNAME: $global:HOSTNAME"
        Write-Host "REMOTE_COMMAND: $global:REMOTE_COMMAND"
        Write-Host "IDENTITYFILE: $global:IDENTITYFILE"
        Write-Host "JOB_NAME: $global:JOB_NAME"
    }
}

Function Allocate-Resources {
    # Allocate resources using slurm using salloc (currently defined in ssh_config RemoteCommand - e.g. RemoteCommand salloc --no-shell -n 1 -c 4 -J vscode --time=1:00:00)

    if ($DEBUGMODE) {
        Write-Host "Allocating resources..."
    }

    # Extend the remote command to check for the job first, if it doesn't exist, reserve the resources, 
    # then print the allocated node name to stderr after the salloc command completes and a node is assigned. 
    # Example: NODE: node1
    $global:REMOTE_COMMAND = "FOUND_JOB=`$(squeue --user=$global:REMOTE_USERNAME --name=$global:JOB_NAME --states=R,PD -h -O JobID) && `
    if [[ ! -z `"`$FOUND_JOB`" ]]; then `
        >&2 echo `"Job $global:JOB_NAME already exists. Skipping resource reservation. Granted job allocation `$FOUND_JOB`"; `
    else `
        $global:REMOTE_COMMAND; `
    fi; >&2 echo `"NODE: `$(squeue --user=$global:REMOTE_USERNAME --name=$global:JOB_NAME --states=R -h -O Nodelist | awk '{print `$1}')`""

    $execCmd = {
        & $using:SSH_BINARY -o StrictHostKeyChecking=no -o ConnectTimeout=$using:global:CONNECT_TIMEOUT -i $using:global:IDENTITYFILE "$($using:global:REMOTE_USERNAME)@$($using:global:HOSTNAME)" $using:global:REMOTE_COMMAND 2>&1
    }

    # Start the command and store the job object
    $job = Start-Job -ScriptBlock $execCmd

    # Wait for the job to complete
    Wait-Job $job

    # Get the output from the job
    $ALLOC_OUTPUT = Receive-Job $job

    if ($DEBUGMODE) {
        Write-Host "Modified REMOTE_COMMAND: $($global:REMOTE_COMMAND)"
        Write-Host "Here's ALLOC_OUTPUT: $ALLOC_OUTPUT"
    }
    $ALLOC_OUTPUT = $ALLOC_OUTPUT | Out-String | ForEach-Object { $_ -replace "`r`n", " " }
    # Extract the job id and node name
    $global:JOBID = ($ALLOC_OUTPUT -split "Granted job allocation ")[1].Split(" ")[0]
    $global:NODE = ($ALLOC_OUTPUT -split "NODE: ")[1].Split(" ")[0]
    $global:NODE = Extract-Prefix-And-Number $global:NODE
    if ($DEBUGMODE) {
        Write-Host "JOBID: $global:JOBID"
        Write-Host "NODE: $global:NODE"
    }
}

# Process command-line arguments
if ($args[0] -ceq "-V") {
    & $SSH_BINARY $args
} else {
    $joinedArgs = $args -join " "
    $portPattern = '-D\s[0-9]+'
    $portMatches = Select-String -InputObject $joinedArgs -Pattern $portPattern -AllMatches
    $conntimeoutPattern = 'ConnectTimeout=\d+'
    $conntimeoutMatches = Select-String -InputObject $joinedArgs -Pattern $conntimeoutPattern -AllMatches
    
    # Check if we found any matches before proceeding
    if ($portMatches -and $portMatches.Matches.Count -gt 0) {
        $PORT = $portMatches.Matches[0].Value.Split(' ')[1]
    } else {
        # Default action or handling if no matches are found
        $PORT = $null
    }

    $global:CONNECT_TIMEOUT = ""
    if ($conntimeoutMatches -and $conntimeoutMatches.Matches.Count -gt 0) {
        $global:CONNECT_TIMEOUT = $conntimeoutMatches.Matches[0].Value.Split('=')[1]
    } else {
        $global:CONNECT_TIMEOUT = 120
    }
    
    if ($DEBUGMODE) { Write-Host "string: $joinedArgs"; "PORT: $PORT"; Write-Host "CONNECT_TIMEOUT: $CONNECT_TIMEOUT"}

    $REMOTE_HOST = $args[-1]

    if ($REMOTE_HOST -eq "bash") {
        $REMOTE_HOST = $args[-2]
    }
    
    if ($DEBUGMODE) { Write-Host "REMOTE_HOST: $REMOTE_HOST" }

    Extract-SSH-Config $REMOTE_HOST
    
    # Before checking $REMOTE_COMMAND, ensure it's been properly tried to be set
    if ($null -ne $REMOTE_COMMAND -and $REMOTE_COMMAND -like "*salloc*") {
        
        $stdin_commands = $input | Out-String | ForEach-Object { $_ -replace "`r`n", " " }
        
        if ($stdin_commands -eq "") {
            $stdin_commands = "echo `"No commands to run`""
        }

        Allocate-Resources

        # if ($DEBUGMODE) {
        #     Write-Host "Running commands on remote host"
        #     Write-Host $stdin_commands
        # }
        
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
        
        if ($WATCHER_SETTING -eq "socket") {
            $WATCHER_TEXT="sleep 120; `
            `$SS_LOC -a -p -n -e | grep code | grep tcp | grep ESTAB | grep `$(id -u) && `
            while [ `$? -eq 0 ]; do sleep 1; `$SS_LOC -a -p -n -e | grep code | grep tcp | grep ESTAB | grep `$(id -u); done;"
        } else {
            $WATCHER_TEXT="echo `"watching ppid: `$ssh_pid`"; `
            N=0; `
            while kill -0 `$ssh_pid 2>/dev/null; do sleep 1; N=`$N+1; done;"
        }
        
        $SRUN_COMMAND="ssh_pid=`$(echo `$SSH_AUTH_SOCK | cut -d`".`" -f2); `
            kill -9 `$(head -n 1 `$HOME/.WATCHER_VSC_$global:REMOTE_USERNAME 2>/dev/null) 2>/dev/null; `
            export SS_LOC=`$(which ss 2>/dev/null) && `
            (echo `$`$ > `$HOME/.WATCHER_VSC_$global:REMOTE_USERNAME; `
            $WATCHER_TEXT `
            sleep $SCANCEL_TIMEOUT; `
            scancel $global:JOBID; `
            rm `$HOME/.WATCHER_VSC_$global:REMOTE_USERNAME; `
            exit 0;) & disown -h && `
            exec /bin/bash --login"

        if ($DEBUGMODE) {
            Write-Host "'$SRUN_COMMAND'"
        }

        & $SSH_BINARY -F $SSH_CONFIG_FILE -T -A -i $global:IDENTITYFILE -D $PORT `
        -o StrictHostKeyChecking=no -o ConnectTimeout=$global:CONNECT_TIMEOUT `
        -J "$global:REMOTE_USERNAME@$global:HOSTNAME" "$global:REMOTE_USERNAME@$global:NODE" `
        srun --overlap --jobid $global:JOBID /bin/bash -lc "'$SRUN_COMMAND'"
        
    } else {
        if ($DEBUGMODE) {
            Write-Host "Executing SSH command normally"
            Write-Host $SSH_BINARY $args
        }
        & $SSH_BINARY $args
    }
}
