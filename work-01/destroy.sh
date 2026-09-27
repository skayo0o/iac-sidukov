export PREFIX=sidukov-08
 
yc compute instance delete "$PREFIX-app-1"
yc compute instance delete "$PREFIX-app-2"
 
yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"
 
yc compute instance list
yc vpc network list
yc compute disk list