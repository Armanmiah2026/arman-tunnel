package com.trilead.ssh2.signature;

import java.math.BigInteger;

/**
 * DSAPrivateKey.
 *
 * @author Christian Plattner, plattner@trilead.com
 * @version $Id: DSAPrivateKey.java,v 1.1 2007/10/15 12:49:57 cplattne Exp $
 * @see java.security.interfaces.DSAPrivateKey
 * @deprecated use {@link java.security.interfaces.DSAPrivateKey}
 */
@Deprecated
public class DSAPrivateKey {
    private final BigInteger p;
    private final BigInteger q;
    private final BigInteger g;
    private final BigInteger x;
    private final BigInteger y;

    public DSAPrivateKey(BigInteger p, BigInteger q, BigInteger g,
                         BigInteger y, BigInteger x) {
        this.p = p;
        this.q = q;
        this.g = g;
        this.y = y;
        this.x = x;
    }

    public BigInteger getP() {
        return p;
    }

    public BigInteger getQ() {
        return q;
    }

    public BigInteger getG() {
        return g;
    }

    public BigInteger getY() {
        return y;
    }

    public BigInteger getX() {
        return x;
    }

    public DSAPublicKey getPublicKey() {
        return new DSAPublicKey(p, q, g, y);
    }
}