import std.stdio;
import enet.enet;
import server;
import gameserver.client;
import gameserver.common;
import core.stdc.signal;
import core.thread;
import std.datetime.stopwatch;
import std.conv;

__gshared bool running;

extern(C) void sighandler(int signo) @nogc nothrow @system {
    running = false;
}

struct ChatMessage
{
    string msg;
}

void main(string[] args)
{
    enet_initialize();
    scope(exit) enet_deinitialize();

    running = true;
    signal(SIGINT, &sighandler);
    if(args.length > 1)
    {
        // client mode
        Client client;
        writeln("Connecting to localhost");
        client.initialize("localhost", 6666);
        client.onMsg((size_t peerid, ChatMessage c) {
                                 writeln("Got a chat message from ", peerid, ": ", c.msg);
                                 });
        // every 1 seconds, send a chat
        if(args.length > 2) {
            int targetRoom = args[2].to!int;
            client.send(MoveToRoom(targetRoom));
        }
        auto sw = StopWatch(AutoStart.yes);
        while(running)
        {
            client.process();
            Thread.sleep(10.msecs);
            if(sw.peek > 1.seconds)
            {
                client.send(ChatMessage(args[1]));
                sw.reset;
            }
        }
        client.disconnect();
    }
    else
    {
        Server server;
        server.initialize(6666);
        while(running)
            server.process(1000);
    }
    writeln("Exiting...");
}
