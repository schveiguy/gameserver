module server;
import gameserver.common;

import enet.enet;
import iopipe.json.serialize;
import iopipe.json.parser;
import iopipe.bufpipe;
import std.range;

auto addrStr(ENetAddress addr)
{
    static struct Printer
    {
        ENetAddress addr;
        void toString(Out)(Out output)
        {
            import std.format : formattedWrite;
            foreach(i; 0 .. 4)
            {
                auto octet = (addr.host >> (8 * i)) & 0xff;
                formattedWrite(output, "%s%d", i > 0 ? "." : "", octet);
            }
            formattedWrite(output, ":%d", addr.port);
        }
    }
    return Printer(addr);
}

struct Server
{
    private {
        struct Room
        {
            int id;
            ENetPeer*[] players;
            bool removePlayer(size_t id)
            {
                import std.algorithm : remove, SwapStrategy;
                auto origLen = players.length;
                players = players.remove!(v => cast(size_t)v.data == id, SwapStrategy.stable);
                players.assumeSafeAppend;
                assert(players.length != origLen);
                // return true if this room can be removed. Room id 0 must
                // always be present.
                return this.id != 0 && players.length == 0;
            }
        }

        ENetHost *host;
        size_t clientId;
        int roomId;
        ClientInfo[] players;
        Room[] rooms = [Room(0, null)];
        BufferPipe msg; // TODO: instead of this, use an iopipe buffer with malloc.
    }

    void initialize(ushort port) {
        ENetAddress *addr = new ENetAddress;
        addr.host = ENET_HOST_ANY;
        addr.port = port;
        this.host = enet_host_create(addr, 10, 2, 0, 0);
    }

    // send and receive messages
    void process(uint timeout)
    {
        ENetEvent event;
        auto res = enet_host_service(host, &event, timeout);
        if(res < 0)
            throw new Exception("Error in servicing host");
        final switch(event.type)
        {
        case ENET_EVENT_TYPE_NONE:
            break;
        case ENET_EVENT_TYPE_CONNECT:
            handleConnect(event);
            break;
        case ENET_EVENT_TYPE_RECEIVE:
            handlePacket(event);
            break;
        case ENET_EVENT_TYPE_DISCONNECT:
            handleDisconnect(event);
            break;
        }
    }

    private void handlePacket(ref ENetEvent event)
    {
        // rebroadcast the data to the clients, but of course, put in the client id
        import std.conv : toChars;
        import std.stdio;
        auto eventmsg = (cast(const char *)event.packet.data)[0 .. event.packet.dataLength];
        // if the message is one we recognize, then handle it, otherwise, send
        // it to the related peers

        auto client = getClient(event); 
        assert(client);
        auto tokens = eventmsg.jsonTokenizer!(false);
        tokens.startCache();
        if(!tokens.parseTo("typename"))
        {
            writeln("Ignoring malformed packet: ", eventmsg);
            return; // ignore this, no idea how to handle it
        }
        scope(failure) writeln("Could not parse packet :", eventmsg);
        auto item = tokens.next;
        jsonExpect(item, JSONToken.String, "Expected type name");
        auto typename = item.data(eventmsg);
        if(typename == "MoveToRoom")
        {
            tokens.rewind();
            tokens.endCache();
            if(!tokens.parseTo("value"))
            {
                // ignore
                writeln("Ignoring malformed packet: ", eventmsg);
                return;
            }
            auto mtr = deserialize!MoveToRoom(tokens);
            writeln("processing move to room, ", mtr);
            if(mtr.id == -1)
            {
                rooms.length = rooms.length + 1;
                rooms[$-1].id = ++roomId;
                mtr.id = roomId;
                writeln("Adding room id ", roomId);
            }

            auto room = getRoom(mtr.id);
            if(!room)
            {
                // ignore
                writeln("Ignoring incorrect move to room, ", eventmsg);
                return;
            }
            auto curRoom = getRoom(client.room_id);
            if(curRoom)
                if(curRoom.removePlayer(client.id))
                    removeRoom(curRoom);
            room.players ~= event.peer;
            client.room_id = room.id;
            // send out a message to all players about the move
            auto packet = makePacket(ClientInfoChanged(*client));
            enet_host_broadcast(host, 0, packet);
        }
        else
        {
            // send the message to all peers in the same room
            enum header =`{"id": `;
            auto idr = toChars(client.id);
            ENetPacket *packet = enet_packet_create(null,
                eventmsg.length + // message
                idr.length + // id
                header.length, // header length (substitute { for ,)
                ENET_PACKET_FLAG_RELIABLE);
            auto msg = (cast(char *)packet.data)[0 .. packet.dataLength];
            // write the jsonmsg, while also putting in the id.
            put(msg, header);
            put(msg, idr);
            put(msg, ',');
            put(msg, eventmsg[1 .. $]); // skip opening brace
            assert(msg.length == 0);
            // send to all the clients in the room
            auto room = getRoom(client.room_id);
            //assert(room);
            if(!room) // this shouldn't happen, but don't want to crash.
            {
                stderr.writeln("Client id ", client.id, " Is in invalid room id ", client.room_id);
                return;
            }
            foreach(p; room.players)
            {
                enet_peer_send(p, 0, packet);
            }
        }
    }

    private ENetPacket *makePacket(T)(T value)
    {
        static struct MsgStruct {
            string typename;
            T value;
        }

        auto packetData = MsgStruct(T.stringof, value);
        auto datasize = serialize!(ReleaseOnWrite.no)(msg, packetData);
        auto pkt = enet_packet_create(msg.window.ptr, datasize, ENET_PACKET_FLAG_RELIABLE);
        if(!pkt)
            throw new Exception("Could not create packet");
        return pkt;
    }

    private void handleConnect(ref ENetEvent event)
    {
        // send the peer a message telling him his client id
        import std.format : format;
        ++clientId;
        import std.stdio;
        writeln("Client connected from ", event.peer.address.addrStr, " assigning id ", clientId);
        auto newClient = ClientInfo(clientId, 0);
        auto hello = Hello(ClientInfo(clientId, 0), players);
        ENetPacket *packet = makePacket(hello);
        event.peer.data = cast(void *)clientId;
        enet_peer_send(event.peer, 0, packet);
        players ~= newClient;
        rooms[0].players ~= event.peer;

        // tell all clients that a client was added
        auto clientAdded = ClientAdded(newClient);
        packet = makePacket(clientAdded);
        enet_host_broadcast(host, 0, packet);
    }

    private ClientInfo *getClient(ref ENetEvent event)
    {
        return getClient(cast(size_t)event.peer.data);
    }

    private ClientInfo *getClient(size_t id)
    {
        import std.algorithm : find;
        import std.format : format;
        auto searched = players.find!((ref p, x) => p.id == x)(id);
        if(searched.empty())
            return null;
        return &searched.front();
    }

    private Room *getRoom(int id)
    {
        import std.algorithm : find;
        import std.format : format;
        auto searched = rooms.find!((ref p, int x) => p.id == x)(id);
        if(searched.empty())
            return null;
        return &searched.front();
    }

    private void handleDisconnect(ref ENetEvent event)
    {
        // tell clients that the client disconnected
        import std.format : format;
        auto client = *getClient(event);
        import std.stdio;
        writeln("Client disconnected from address ", event.peer.address.addrStr, " with id ", client.id);
        auto clientRemoved = ClientRemoved(client.id);
        auto packet = makePacket(clientRemoved);
        enet_host_broadcast(host, 0, packet);
        // ensure the peer is removed from the list and from its room
        import std.algorithm : remove, SwapStrategy;
        auto origLen = players.length;
        players = players.remove!(v => v.id == client.id, SwapStrategy.stable);
        assert(players.length != origLen);
        players.assumeSafeAppend;
        auto room = getRoom(client.room_id);
        assert(room);
        if(room.removePlayer(client.id))
            removeRoom(room);
        // do this last. Because we use it to identify peers.
        event.peer.data = null;
    }

    private void removeRoom(Room *ptr)
    {
        assert(ptr.players.length == 0);
        import std.stdio;
        writeln("Removing room id ", ptr.id);
        size_t idx = ptr - rooms.ptr;
        assert(idx != 0 && idx < rooms.length);
        rooms[idx] = rooms[$-1];
        rooms.length = rooms.length - 1;
        rooms.assumeSafeAppend;
    }
}

