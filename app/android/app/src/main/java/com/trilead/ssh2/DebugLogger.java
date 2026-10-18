package com.trilead.ssh2;

/**
 * An interface which needs to be implemented if you
 * want to capture debugging messages.
 *
 * @author Christian Plattner, plattner@trilead.com
 * @version $Id: DebugLogger.java,v 1.1 2008/03/03 07:01:36 cplattne Exp $
 * @see Connection#enableDebugging(boolean, DebugLogger)
 * @deprecated Logging all goes to JDK java.util.logging
 */
@Deprecated
public interface DebugLogger {

    /**
     * Log a debug message.
     *
     * @param level     0-99, 99 is a the most verbose level
     * @param className the class that generated the message
     * @param message   the debug message
     */
    void log(int level, String className, String message);
}
