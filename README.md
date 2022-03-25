# Simple GameServer

Based on enet, this simple game server provides a mechanism to supply messages to connected clients.

Messages are *wholly determined by the clients*, except for client management services.

Client management services:

1. A client can create a room by using the MoveToRoom(-1) message. This will put the client in a new room with a new id.
2. A client can move to an existing room by using the MoveToRoom(id) message (where id is the id of the room).
3. Any rooms which have no clients will be removed from the server, with the exception of room 0, which is the default room (lobby).
4. Any messages sent by a client are broadcast to all clients in the room (including the sender).
5. Room moves are broadcast to *all* clients.

Please see the server's mini-client code for how to use, very low docs so far, but I will add to it.

## TODO:

1. Room order (on the server, the clients that connect to a room are added in order, but this information is not conveyed to the clients). This can help with who "owns" a room, or what player 1, player 2, etc. are.
2. Easier methods to move to a room in the Client type.
3. Game-specific status for each client (aside from rooms). e.g. name, health, etc. so new clients don't need to rely on the other clients broadcasting this info to them.
4. Better CLI for server.
5. More management systems (security, ids etc) -- a long way off.

## Server

To build the server, use `dub build :server` in the source directory. You need to have the enet library installed and linkable from your OS/local directory. Dub is kind of bad at having a good common place for external libs.

The server currently has a "client mode" to test it. But generally just run the server directly. No real options yet, it will be added.

This server has NO real options for security or anything. Do not use this server in your production game!
