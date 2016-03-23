module vibe.db.postgresql.pool;

import core.sync.semaphore;
import vibe.core.log;
import std.conv: to;
import core.atomic;

private synchronized class ConnectionsStorage(TConnection)
{
    private:

    import std.container.dlist;

    DList!TConnection freeConnections;

    TConnection getConnection()
    {
        if((cast() freeConnections).empty)
        {
            return null;
        }
        else
        {
            TConnection conn = (cast() freeConnections).front;
            (cast() freeConnections).removeFront;
            return conn;
        }
    }

    void revertConnection(TConnection conn)
    {
        (cast() freeConnections).insertBack(conn);
    }
}

shared class ConnectionPool(TConnection)
{
    private:

    ConnectionsStorage!TConnection storage;
    TConnection delegate() connectionFactory;
    Semaphore maxConnSem;
    uint[TConnection] connNum;

    public:

    this(TConnection delegate() connectionFactory, uint maxConcurrent = uint.max)
    {
        this.connectionFactory = cast(shared) connectionFactory;
        storage = new shared ConnectionsStorage!TConnection;
        maxConnSem = cast(shared) new Semaphore(maxConcurrent);
    }

    /// Non-blocking. Useful for fibers
    bool tryLockConnection(LockedConnection!TConnection* conn)
    {
        if((cast() maxConnSem).tryWait)
        {
            logDebugV("lock connection");
            *conn = getConnection();
            return true;
        }
        else
        {
            logDebugV("no free connections");
            return false;
        }
    }

    /// Blocking. Useful for threads
    @disable // unused code
    LockedConnection!TConnection lockConnection()
    {
        (cast() maxConnSem).wait();

        return getConnection();
    }

    private LockedConnection!TConnection getConnection()
    {
        scope(failure) (cast() maxConnSem).notify();

        TConnection conn = storage.getConnection;

        if(conn !is null)
        {
            logDebugV("used connection return");
        }
        else
        {
            logDebugV("new connection return");
            conn = connectionFactory();
        }

        connCounter(counterOp.INIT, conn);

        return LockedConnection!TConnection(this, conn);
    }

    /// If connection is null (means what connection was failed etc) it
    /// don't reverted to the connections list
    private void releaseConnection(TConnection conn)
    {
        logDebugV("releaseConnection()");

        if(!connCounter(counterOp.DECREMENT, conn))
        {
            if(conn !is null) storage.revertConnection(conn);

            (cast() maxConnSem).notify();
        }
    }

    /// returns true if connections are remained
    private bool connCounter(counterOp op, TConnection conn)
    {
        import core.atomic: atomicOp;

        synchronized
        {
            with(counterOp)
            final switch(op)
            {
                case INIT:
                    logDebugV("init counter");
                    assert((conn in connNum) is null);
                    connNum[conn] = 1;
                    return true;

                case INCREMENT:
                    logDebugV("increment counter");
                    connNum[conn].atomicOp!"+="(1);
                    return true;

                case DECREMENT:
                    logDebugV("decrement counter");
                    connNum[conn].atomicOp!"-="(1);
                    if(connNum[conn] == 0)
                    {
                        connNum.remove(conn);
                        return false;
                    }
                    else
                    {
                        return true;
                    }
            }
        }
    }
}

private enum counterOp
{
    INCREMENT,
    DECREMENT,
    INIT
}

struct LockedConnection(TConnection)
{
    private shared ConnectionPool!TConnection pool;
    private TConnection _conn;

    @property ref TConnection conn()
    {
        return _conn;
    }

    package alias conn this;

    void dropConnection()
    {
        assert(_conn);

        destroy(_conn);
        _conn = null;
    }

    private this(shared ConnectionPool!TConnection pool, TConnection conn)
    {
        this.pool = pool;
        this._conn = conn;
    }

    ~this()
    {
        logDebugV("LockedConn destructor");
        if(pool) // TODO: remove this check
        {
            pool.releaseConnection(conn);
        }
    }

    this(this)
    {
        pool.connCounter(counterOp.INCREMENT, _conn);
    }
}
