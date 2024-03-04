# vscode_remote_slurm
Helper script for executing commands before connecting to vscode remote. This can be used to run vscode remote on the compute node of a slurm cluster.  
Conditionally wraps the ssh command if `salloc` is in the RemoteCommand. Passes through otherwise.  
This seems to work for Mac + Linux. Notes about potential use on Windows are detailed below.

### Changelog:
2024-03-01: 
- Less ssh commands needed to reserve jobs, so connecting is much quicker.
- Cancelling the job is no longer done when before you connect, and instead, a subprocess is created and waits to watch the connection stop on your local machine, and it then sends an scancel command after disconnect.

### How I have been able to get this working:  
- Put the ssh_wrapper.sh script somewhere.
- Make sure it's executable: `chmod +x ssh_wrapper.sh`
- Change vscode to run this instead of your default ssh binary.
- Create a host entry in your ssh_config (example below) with a RemoteCommand detailing your resources.
- Hope it works?

### How it works
The script:

- Pretends to be ssh and intercepts the ssh commands sent from vscode,
- Uses salloc to reserve resources on the cluster (currently set in the RemoteCommand in the ssh_config),
- Figures out where those resources are,
- Proxyjumps through the login node and runs bash within the Slurm allocation using srun,
- Allows vscode to continue to send its commands to the bash shell on the compute node to run the remote server.

### On Windows:
This might work by using WSL2 and setting up the ssh_config and ssh_wrapper.sh in the WSL2 environment, and ProxyJumping connections through the WSL2 environment. Here's the idea I'm playing around with:

Start by setting up WSL2 and installing a Linux distro. Then install and start an [sshd instance](https://www.hanselman.com/blog/how-to-ssh-into-wsl2-on-windows-10-from-an-external-machine) (listening on a different port than 22 to not confuse things). Verify you can connect to it.

Now let's attempt to detect which OS we're using right at the start of the ssh config. You can [detect if you're on windows](https://creechy.wordpress.com/2021/02/03/quest-for-a-multi-platform-ssh-config/) in your ssh config like so:
```
Match host="!machine1-wsl2,*" exec "exit ${ONWINDOWS:=1}"
  ProxyJump machine1-wsl2
``` 
This means that if you're on a windows machine, for any host besides the WSL2 machine itself, it will jump through the machine1-wsl2 host to get to the remotehost. When connecting to machine1 directly, it will not ProxyJump to itself

You can define a connection to WSL2 in your ssh_config like so:
```
Host machine1-wsl2
  HostName 172.19.162.172 # This is the IP of the WSL2 VM
  IdentityFile ~/.ssh/id_rsa
  Port 2224
  Compression no
  ForwardAgent yes
  User xangma
```

Now any connections to remotehost will be proxied through the WSL2 machine. You can set up the ssh_wrapper.sh and ssh_config in the WSL2 environment and connect to the remotehost.

### TODO:  
- Wrap into extension so it runs this script on a button press instead of changing vscode to only use this script for ssh.


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
