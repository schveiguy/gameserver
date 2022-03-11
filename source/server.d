module server;

import enet.enet;

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
    ENetHost *host;
    size_t clientId;
    size_t[] peerIds;
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
            assignId(event);
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
        import std.range : put;
        auto eventmsg = (cast(const char *)event.packet.data)[0 .. event.packet.dataLength];
        auto idr = toChars(cast(size_t)event.peer.data);
        enum header =`{"id": `;
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
        enet_host_broadcast(host, 0, packet);
    }

    private void assignId(ref ENetEvent event)
    {
        // send the peer a message telling him his client id
        import std.format : format;
        ++clientId;
        import std.stdio;
        writeln("Client connected from ", event.peer.address.addrStr, " assigning id ", clientId);
        string packetData = format(`{"typename": "Hello", "value": {"id": %d, "clients": %s}}`, clientId, peerIds);
        event.peer.data = cast(void *)clientId;
        peerIds ~= clientId;
        ENetPacket *packet = enet_packet_create(packetData.ptr, packetData.length, ENET_PACKET_FLAG_RELIABLE);
        enet_peer_send(event.peer, 0, packet);

        // tell all clients that a client was added
        packetData = format(`{"typename": "ClientAdded", "value": {"id": %d}}`, clientId);
        packet = enet_packet_create(packetData.ptr, packetData.length, ENET_PACKET_FLAG_RELIABLE);
        enet_host_broadcast(host, 0, packet);
    }

    private void handleDisconnect(ref ENetEvent event)
    {
        // tell clients that the client disconnected
        import std.format : format;
        auto removingId = cast(size_t)event.peer.data;
        import std.stdio;
        writeln("Client disconnected from address ", event.peer.address.addrStr, " with id ", removingId);
        string packetData = format(`{"typename": "ClientRemoved", "value": {"id": %d}}`, removingId);
        auto packet = enet_packet_create(packetData.ptr, packetData.length, ENET_PACKET_FLAG_RELIABLE);
        enet_host_broadcast(host, 0, packet);
        // ensure the peer is removed
        event.peer.data = null;
        import std.algorithm : remove, SwapStrategy;
        peerIds = peerIds.remove!(v => v == removingId, SwapStrategy.unstable);
        peerIds.assumeSafeAppend;
    }
}

