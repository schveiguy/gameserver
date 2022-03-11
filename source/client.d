module client;

import enet.enet;
import iopipe.json.serialize;
import iopipe.json.parser;
import iopipe.bufpipe;
import std.exception;

version(Windows)
    import core.sys.windows.winsock2;
else version(Posix)
    import core.sys.posix.netdb;
else
    static assert(0, "Unknown OS");

alias BufferPipe = typeof(bufd!char());

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
    BufferPipe msg; // TODO: see if I can find a way to allocate packets directly with iopipe

    Converter[string] handlers;
    }

    private struct Hello
    {
        size_t id;
        size_t[] clients;
    }

    private struct ClientAdded {
        size_t id;
    }

    private struct ClientRemoved {
        size_t id;
    }

    // your id
    size_t id = 0;
    // list of peer clients
    size_t[] validPeers;

    void initialize(string host, ushort port) {
        import std.string;
        if(this.host is null)
            this.host = enet_host_create(null, 1, 2, 0, 0);
        ENetAddress addr;
        addr.port = port;
        auto ent = gethostbyname(host.toStringz);
        if(ent is null)
        {
            // error
            throw new Exception("Error looking up host infomration for " ~ host);
        }
        auto ipaddr = ent.h_addr_list;
        if(!ipaddr || !*ipaddr)
        {
            throw new Exception("Not able to find valid IP address for " ~ host);
        }
        addr.host = (cast(in_addr*)*ipaddr).s_addr;
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
            server = enet_host_connect(this.host, &addr, 2, 0);
            if(server is null)
                throw new Exception("Error, attempt to connect to host failed");
        }

        // process client messages
        onMsg(&processHello);
        onMsg(&processClientAdded);
        onMsg(&processClientRemoved);
    }

    void disconnect()
    {
        if(server !is null)
        {
            enet_peer_disconnect_later(server, 0);
            while(server !is null)
                process();
        }
    }
    
    private void processHello(size_t, Hello h) {
        this.id = h.id;
        this.validPeers = h.clients;
        import std.stdio;
        writeln("Connected with id ", this.id, ", existing peers are ", validPeers);
    }

    private void processClientAdded(size_t, ClientAdded ca) {
        import std.stdio;
        if(ca.id != this.id)
        {
            this.validPeers ~= ca.id;
            writeln("Peer added with id ", ca.id, " valid peers now ", validPeers);
        }
    }

    private void processClientRemoved(size_t, ClientRemoved cr) {
        import std.algorithm : remove, SwapStrategy;
        import std.stdio;
        validPeers = validPeers.remove!(v => v == cr.id, SwapStrategy.unstable);
        validPeers.assumeSafeAppend;
        writeln("Peer removed with id ", cr.id, " valid peers now ", validPeers);
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

    void send(T)(T value)
    {
        static struct msgStruct {
            string typename;
            T value;
        }
        auto packetData = msgStruct(T.stringof, value);
        import std.exception : enforce;
        enforce(server !is null, "Need to open connection first");
        // serialize to json, then put into a packet.
        auto datasize = serialize!(ReleaseOnWrite.no)(msg, packetData);
        auto pkt = enet_packet_create(msg.window.ptr, datasize, ENET_PACKET_FLAG_RELIABLE);
        if(!pkt)
            throw new Exception("Could not create packet");
        enet_peer_send(server, 0, pkt);
    }

    // send and receive messages
    void process()
    {
        ENetEvent event;
        while(true)
        {
            auto res = enet_host_service(host, &event, 0);
            if(res < 0)
                throw new Exception("Error in servicing host");
            if(res == 0)
                return;
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
        enforce(converter !is null);
        tokens.rewind();
        tokens.endCache();
        enforce(tokens.parseTo("value"));

        // set up to process the value
        converter.process(tokens, peerid, converter.dg);
    }
}
