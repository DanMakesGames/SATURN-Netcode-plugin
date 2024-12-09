### SATURN Netcode
<ins>S</ins>erver
<ins>A</ins>uthenticated
<ins>T</ins>hrottle
<ins>U</ins>pstream
<ins>N</ins>etcode

Inspired by GGPO to bring low latency accurate gameplay to players. This netcode library utilizes rollback and prediction to provide accurate low latency gameplay. Unlike GGPO, and it has a authoritative dedicated server.
Very much still in progress.

### Features:
* Athoritative Dedicated Server
* Client-side rollback and prediction
* Server input buffer.

### Planned Features:
* Upstream Throttling: Speed up or slow down clients to ensure they dont get too far ahead or behind the server.
* C++ port: I'd like to re-write this in C++ to improve performance. 

### Inspirations
* https://old-forum.warthunder.com/index.php?/topic/382575-development-shell-and-bullet-synchronization/ : War Thunder's netcode.
* https://youtu.be/ueEmiDM94IE?si=pheS1wSau_jq6vuJ: Rocket League netcode presentation. Where I got the idea to do upstream throttling. Originally I was going to do rollbacks on the SERVER and CLIENT, as that appears to be how War Thunder does things. This ended up being a nightmare, and introduced many over-complications in reguards to 
* https://youtu.be/W3aieHjyNvw?si=Sn_TZGUsEwKpLQcJ: Overwatch netcode presentation.
* https://gafferongames.com : The best set of articles on netcode.
* https://gitlab.com/snopek-games/godot-rollback-netcode/ : Incredible tutorial series on implementing peer to peer Rollback netcode.
