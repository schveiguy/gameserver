module gameserver.common;

import iopipe.bufpipe;

alias BufferPipe = typeof(bufd!char());

// client info 
struct ClientInfo
{
    size_t id;
    int room_id = 0;
}

struct Hello
{
    ClientInfo info;
    ClientInfo[] clients;
}

struct MoveToRoom
{
    int id = -1;
}

struct ClientAdded
{
    ClientInfo info;
}

struct ClientInfoChanged
{
    ClientInfo info;
}

struct ClientRemoved
{
    size_t id;
}
