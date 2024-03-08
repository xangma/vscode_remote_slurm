# Set-StrictMode -Version Latest

$SSH_BINARY = Get-Command ssh.exe | Select-Object -ExpandProperty Source
$SSH_CONFIG_FILE = Join-Path $HOME ".ssh\config"
$DEBUGMODE = $true
$SCANCEL_TIMEOUT = 60

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
    $global:JOB_NAME = ($global:REMOTE_COMMAND -split "-J ")[1].Split(" ")[0]

    if ($DEBUGMODE) {
        Write-Host "REMOTE_USERNAME: $global:REMOTE_USERNAME"
        Write-Host "HOSTNAME: $global:HOSTNAME"
        Write-Host "REMOTE_COMMAND: $global:REMOTE_COMMAND"
        Write-Host "IDENTITYFILE: $global:IDENTITYFILE"
        Write-Host "JOB_NAME: $global:JOB_NAME"
    }
}

Function Cancel-Existing-Jobs {
    $cmd = "squeue -h -u $global:REMOTE_USERNAME --format=`"%.18i %.50j`" | Select-String $global:JOB_NAME | ForEach-Object { if(\$_ -match '^\d+') {`$matches[0]} } | xargs -r scancel"
    if ($DEBUGMODE) {
        Write-Host "Cancelling existing jobs with $global:JOB_NAME with command $cmd"
    }
    & $SSH_BINARY -q -i $global:IDENTITYFILE $global:REMOTE_USERNAME@$global:HOSTNAME $cmd
    if ($DEBUGMODE) {
        Write-Host "Cancelled existing jobs"
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
        & $using:SSH_BINARY -i $using:global:IDENTITYFILE "$($using:global:REMOTE_USERNAME)@$($using:global:HOSTNAME)" $using:global:REMOTE_COMMAND 2>&1
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
    
    # Check if we found any matches before proceeding
    if ($portMatches -and $portMatches.Matches.Count -gt 0) {
        $PORT = $portMatches.Matches[0].Value.Split(' ')[1]
    } else {
        # Default action or handling if no matches are found
        $PORT = $null
    }
    
    if ($DEBUGMODE) { Write-Host "PORT: $PORT" }

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
            $stdin_commands = "echo 'No commands to run'"
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

        & $SSH_BINARY -T -A -i $global:IDENTITYFILE -D $PORT `
        -o StrictHostKeyChecking=no `
        -J "$global:REMOTE_USERNAME@$global:HOSTNAME" "$global:REMOTE_USERNAME@$global:NODE" `
        srun --overlap --jobid $global:JOBID /bin/bash -c `
        "'ssh_pid=`$(echo `$SSH_AUTH_SOCK | cut -d`".`" -f2); `
        kill -9 `$(cat .WATCHER_VSC_$global:REMOTE_USERNAME); `
        (echo `$`$ > .WATCHER_VSC_$global:REMOTE_USERNAME; `
        echo `"watching ppid: `$ssh_pid`"; `
        while kill -0 `$ssh_pid 2>/dev/null; do sleep 1; done; `
        sleep $SCANCEL_TIMEOUT && scancel $global:JOBID; `
        rm .WATCHER_VSC_$global:REMOTE_USERNAME; exit 0) & disown -h && `
        exec /bin/bash --login'"
        
    } else {
        if ($DEBUGMODE) {
            Write-Host "Executing SSH command normally"
            Write-Host $SSH_BINARY $args
        }
        & $SSH_BINARY $args
    }
}