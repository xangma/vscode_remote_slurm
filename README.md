# vscode_remote_slurm
Helper script for executing commands before connecting to vscode remote. This can be used to run vscode remote on the compute node of a slurm cluster.  
Conditionally wraps the ssh command if `salloc` is in the RemoteCommand. Passes through otherwise.  
This seems to work for Mac + Linux + Windows!

### Changelog:
2024-03-25:  
Notable changes in this version (cancel-jobs-better):  
- Whole process requires less ssh connections so connecting is quicker.  
- Cancels job on window close/disconnect (after `SCANCEL_TIMEOUT` has elapsed).  
- Reconnects to your job if it finds it running on connecting to the cluster. Say you accidentally closed your vscode window or lost connection, you have `SCANCEL_TIMEOUT` seconds to reconnect before your vscode slurm job is scancelled.  
  
### Requirements
- Key to be added to ssh-agent so agent forwarding works.
- The defined host in the ssh config must not be using Control Sockets.

### How I have been able to get this working:  
- Put the ssh_wrapper.sh script somewhere.
- Make sure it's executable: `chmod +x ssh_wrapper.sh`
- Change vscode to run this instead of your default ssh binary (ctrl + shift + p -> Remote-SSH: Settings -> Remote.SSH: Path: `/full/path/to/ssh_wrapper.sh`)
- Create a host entry in your ssh_config (example below) with a RemoteCommand detailing your resources.
- Hope it works?



### How it works
The script:

- Pretends to be ssh and intercepts the ssh commands sent from vscode,
- Uses salloc to reserve resources on the cluster (currently set in the RemoteCommand in the ssh_config),
- Figures out where those resources are,
- Proxyjumps through the login node and runs bash within the Slurm allocation using srun,
- Allows vscode to continue to send its commands to the bash shell on the compute node to run the remote server.

### TODO:  
- Wrap into extension so it runs this script on a button press instead of changing vscode to only use this script for ssh.
- Check for job already running and reconnect.


Notes:
I have tested this on a Mac M1 connecting to a Centos 7 Slurm Cluster. Vscode Insiders v1.83 and Remote - SSH v0.106.4.  
It hasn't been tested on anything else yet.  

These are my Remote SSH settings:
```
    "remote.SSH.connectTimeout": 60,
    "remote.SSH.logLevel": "trace",
    "remote.SSH.showLoginTerminal": true,
    "remote.SSH.path": "/path/to/ssh_wrapper.sh",
    "remote.SSH.useExecServer": true,
    "remote.SSH.maxReconnectionAttempts": 0,
    "remote.SSH.enableRemoteCommand": true,
    "remote.SSH.useLocalServer": true,
    "remote.SSH.localServerDownload": "off",
    "remote.SSH.path": "/full/path/to/ssh_wrapper.sh",
```


Define your ssh connection in ssh_config like so with your desired slurm allocation:
```
Host remotehost
  HostName your.remote.host
  RequestTTY yes
  ForwardAgent yes
  IdentityFile /path/to/sshkey
  RemoteCommand salloc --no-shell -n 1 -c 4 -J vscode --time=1:00:00
  User remoteusername
```

Connect and hopefully it works.
