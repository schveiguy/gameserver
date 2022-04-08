module gameserver.client;

import gameserver.common;

import enet.enet;
import iopipe.json.serialize;
import iopipe.json.parser;
import iopipe.bufpipe;
import std.exception;
import core.time;

struct Converter
{
    void function(JSONTokenizer!(char[], true), size_t, void delegate() dg) process;
    void delegate() dg;
}

struct Client
{
    private {
    ENetHost *host;
    ENetPeer *server;
    BufferPipe msg;

    Converter[string] handlers;
    void delegate(ClientInfo) addClientHandler;
    void delegate(ClientInfo) removeClientHandler;
    void delegate(ClientInfo) clientMovedHandler;
    }

    // your id
    ClientInfo info;
    // list of peer clients (on the server)
    ClientInfo[] validPeers;
    // list of clients that are in my room.
    ClientInfo[] roomPeers;

    void initialize(string host, ushort port) {
        import std.string;
        if(this.host is null)
            this.host = enet_host_create(null, 1, 2, 0, 0);
        ENetAddress addr;
        addr.port = port;
        if(enet_address_set_host(&addr, host.toStringz) < 0)
        {
            // error
            throw new Exception("Error looking up host infomration for " ~ host);
        }
        if(server !is null)
        {
            if(server.address != addr)
            {
                // TODO: close and open a new connection.
                throw new Exception("Error, client cannot be rebound without being closed first.");
            }
            // else, already open
        }
        else
        {
            // set up the server
            // process client messages
            onMsg(&processHello);
            onMsg(&processClientAdded);
            onMsg(&processClientRemoved);
            onMsg(&processClientInfoChanged);
            server = enet_host_connect(this.host, &addr, 2, 0);
            if(server is null)
                throw new Exception("Error, attempt to connect to host failed");

            // wait at least 1 second for the first client message
            while(!info.id)
            {
                if(!process(1.seconds))
                    throw new Exception("Did not get id from server!");
            }
        }

    }

    void disconnect()
    {
        if(server !is null)
        {
            enet_peer_disconnect_later(server, 0);
            while(server !is null)
                process();
            info = ClientInfo.init;
        }
    }
    
    private void buildRoomPeers()
    {
        import std.algorithm : filter;
        import std.array : array;
        import std.stdio;
        roomPeers = validPeers.filter!((ref c) => c.room_id == info.room_id).array;
        writeln("room peers is now ", roomPeers);
    }

    private void processHello(size_t, Hello h) {
        this.info = h.info;

        this.validPeers = h.clients;
        buildRoomPeers();
        import std.stdio;
        writeln("Connected with info ", this.info, ", existing peers are ", validPeers);
    }

    private void processClientAdded(size_t, ClientAdded ca) {
        import std.stdio;
        if(ca.info.id != this.info.id)
        {
            this.validPeers ~= ca.info;
            // TODO this should be done via logging
            writeln("Peer added with info ", ca.info, " valid peers now ", validPeers);
            if(this.addClientHandler)
                this.addClientHandler(ca.info);
        }
    }

    private void processClientRemoved(size_t, ClientRemoved cr) {
        import std.algorithm : remove, countUntil, SwapStrategy;
        import std.stdio;
        auto clientidx = validPeers.countUntil!((ref v, id) => v.id == id)(cr.id);
        auto removed = validPeers[clientidx];
        validPeers = validPeers.remove(clientidx);
        validPeers.assumeSafeAppend;
        buildRoomPeers();
        writeln("Peer removed with id ", cr.id, " valid peers now ", validPeers);
        if(this.removeClientHandler)
            this.removeClientHandler(removed);
    }

    private void processClientInfoChanged(size_t, ClientInfoChanged cic) {
        import std.algorithm : find, remove, SwapStrategy;
        import std.range : empty, front;
        import std.stdio;
        if(cic.info.id == info.id)
        {
            // I moved
            info = cic.info;
            buildRoomPeers();
        }
        else
        {

            // otherwise, it's a peer
            auto searched = validPeers.find!((ref ci, cid) => ci.id == cid)(cic.info.id);
            if(searched.empty)
                writeln("Peer not found! ", cic.info);
            else {
                auto oldroom = searched.front.room_id;
                searched.front = cic.info;
                if(oldroom == info.room_id || cic.info.room_id == info.room_id)
                    buildRoomPeers();
            }
        }
        if(clientMovedHandler)
            clientMovedHandler(cic.info);
    }

    void onMsg(T)(void delegate(size_t, T) dg)
    {
        // register a handler for type T, which will call the given delegate.
        Converter conv;
        conv.dg = cast(void delegate())dg;
        conv.process = (JSONTokenizer!(char[], true) msg, size_t peerid, void delegate() callback) {
            auto t = deserialize!T(msg);
            (cast(void delegate(size_t, T))callback)(peerid, t);
        };
        handlers[T.stringof] = conv;
    }

    void onMsg(T)(void function(size_t, T) dg)
    {
        import std.functional;
        onMsg(toDelegate(dg));
    }

    void onRemoveClient(void delegate(ClientInfo) dg)
    {
        removeClientHandler = dg;
    }

    void onRemoveClient(void function(ClientInfo) dg)
    {
        import std.functional;
        removeClientHandler = toDelegate(dg);
    }

    void onAddClient(void delegate(ClientInfo) dg)
    {
        addClientHandler = dg;
    }

    void onAddClient(void function(ClientInfo) dg)
    {
        import std.functional;
        addClientHandler = toDelegate(dg);
    }

    void onClientMoved(void delegate(ClientInfo) dg)
    {
        clientMovedHandler = dg;
    }

    void onClientMoved(void function(ClientInfo) dg)
    {
        import std.functional;
        clientMovedHandler = toDelegate(dg);
    }

    void send(T)(T value)
    {
        static struct MsgStruct {
            string typename;
            T value;
        }
        auto packetData = MsgStruct(T.stringof, value);
        import std.exception : enforce;
        enforce(server !is null, "Need to open connection first");
        // serialize to json, then put into a packet.
        auto datasize = serialize!(ReleaseOnWrite.no)(msg, packetData);
        auto pkt = enet_packet_create(msg.window.ptr, datasize, ENET_PACKET_FLAG_RELIABLE);
        if(!pkt)
            throw new Exception("Could not create packet");
        enet_peer_send(server, 0, pkt);
    }

    // send and receive messages with a timeout for at least one message to arrive
    bool process(Duration timeout = 0.seconds)
    {
        ENetEvent event;
        bool result = false;
        while(true)
        {
            auto res = enet_host_service(host, &event, cast(uint)timeout.total!"msecs");
            // reset any timeout, next time we don't want to wait
            timeout = 0.seconds;
            if(res < 0)
                throw new Exception("Error in servicing host");
            if(res == 0)
                break;
            result = true;
            final switch(event.type)
            {
            case ENET_EVENT_TYPE_NONE:
                // shouldn't happen
                break;
            case ENET_EVENT_TYPE_CONNECT:
                // nothing to do
                break;
            case ENET_EVENT_TYPE_RECEIVE:
                handlePacket(event);
                break;
            case ENET_EVENT_TYPE_DISCONNECT:
                server = null;
                break;
            }
        }
        return result;
    }

    private void handlePacket(ref ENetEvent event)
    {
        import std.conv;
        auto packetData = (cast(char*)event.packet.data)[0 .. event.packet.dataLength];
        // deserialize the json
        auto tokens = packetData.jsonTokenizer;
        tokens.startCache();
        size_t peerid = 0;
        JSONItem item;
        if(tokens.parseTo("id"))
        {
            item = tokens.next;
            jsonExpect(item, JSONToken.Number, "Expected client id as a number");
            peerid = item.data(packetData).to!size_t;
        }
        tokens.rewind();
        enforce(tokens.parseTo("typename"), packetData);
        item = tokens.next;
        jsonExpect(item, JSONToken.String, "Expected type name");
        auto converter = item.data(packetData) in handlers;
        if(converter is null)
        {
            import std.stdio;
            writeln("Cannot process message of type `", item.data(packetData), "`");
        }
        else
        {
            tokens.rewind();
            tokens.endCache();
            enforce(tokens.parseTo("value"));

            // set up to process the value
            converter.process(tokens, peerid, converter.dg);
        }
    }
}
