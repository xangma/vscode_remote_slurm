# vscode_remote_slurm
Helper script for executing commands before connecting to remote.


Notes:
I am using this on a Mac M1 connecting to a Slurm Cluster.


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
