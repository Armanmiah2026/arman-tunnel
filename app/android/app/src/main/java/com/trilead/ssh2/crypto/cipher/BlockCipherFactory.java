package com.trilead.ssh2.crypto.cipher;

import java.util.Vector;

/**
 * BlockCipherFactory.
 *
 * @author Christian Plattner, plattner@trilead.com
 * @version $Id: BlockCipherFactory.java,v 1.2 2008/04/01 12:38:09 cplattne Exp $
 */
public class BlockCipherFactory {
    /**
     * Factory for one cipher implementation.
     *
     * Implemented as a direct {@code new} instead of the original
     * {@code Class.forName(name)} reflection: the string form was invisible to
     * R8, so release builds (minifyEnabled) shrank/renamed AES, BlowFish and
     * DESede away. The cipher then failed to instantiate right after KEX and
     * the session died with "Key exchange was not finished, connection is
     * closed." — only in release, never in debug.
     */
    interface CipherSupplier {
        BlockCipher create();
    }

    static class CipherEntry {
        String type;
        int blocksize;
        int keysize;
        CipherSupplier factory;

        public CipherEntry(String type, int blockSize, int keySize, CipherSupplier factory) {
            this.type = type;
            this.blocksize = blockSize;
            this.keysize = keySize;
            this.factory = factory;
        }
    }

    static Vector ciphers = new Vector();

    private static final CipherSupplier AES_SUPPLIER = new CipherSupplier() {
        public BlockCipher create() {
            return new AES();
        }
    };

    private static final CipherSupplier BLOWFISH_SUPPLIER = new CipherSupplier() {
        public BlockCipher create() {
            return new BlowFish();
        }
    };

    private static final CipherSupplier DESEDE_SUPPLIER = new CipherSupplier() {
        public BlockCipher create() {
            return new DESede();
        }
    };

    static {
        /* Higher Priority First */

        ciphers.addElement(new CipherEntry("aes256-ctr", 16, 32, AES_SUPPLIER));
        ciphers.addElement(new CipherEntry("aes192-ctr", 16, 24, AES_SUPPLIER));
        ciphers.addElement(new CipherEntry("aes128-ctr", 16, 16, AES_SUPPLIER));
        ciphers.addElement(new CipherEntry("blowfish-ctr", 8, 16, BLOWFISH_SUPPLIER));

        ciphers.addElement(new CipherEntry("aes256-cbc", 16, 32, AES_SUPPLIER));
        ciphers.addElement(new CipherEntry("aes192-cbc", 16, 24, AES_SUPPLIER));
        ciphers.addElement(new CipherEntry("aes128-cbc", 16, 16, AES_SUPPLIER));
        ciphers.addElement(new CipherEntry("blowfish-cbc", 8, 16, BLOWFISH_SUPPLIER));

        ciphers.addElement(new CipherEntry("3des-ctr", 8, 24, DESEDE_SUPPLIER));
        ciphers.addElement(new CipherEntry("3des-cbc", 8, 24, DESEDE_SUPPLIER));
    }

    public static String[] getDefaultCipherList() {
        String[] list = new String[ciphers.size()];
        for (int i = 0; i < ciphers.size(); i++) {
            CipherEntry ce = (CipherEntry) ciphers.elementAt(i);
            list[i] = ce.type;
        }
        return list;
    }

    public static void checkCipherList(String[] cipherCandidates) {
        for (int i = 0; i < cipherCandidates.length; i++)
            getEntry(cipherCandidates[i]);
    }

    public static BlockCipher createCipher(String type, boolean encrypt, byte[] key, byte[] iv) {
        try {
            CipherEntry ce = getEntry(type);
            BlockCipher bc = ce.factory.create();

            if (type.endsWith("-cbc")) {
                bc.init(encrypt, key);
                return new CBCMode(bc, iv, encrypt);
            } else if (type.endsWith("-ctr")) {
                bc.init(true, key);
                return new CTRMode(bc, iv, encrypt);
            }
            throw new IllegalArgumentException("Cannot instantiate " + type);
        } catch (IllegalArgumentException e) {
            throw e;
        } catch (Exception e) {
            // Keep the real cause: swallowing it is what turned a missing class
            // into an unexplainable "Key exchange was not finished".
            throw new IllegalArgumentException("Cannot instantiate " + type + ": " + e, e);
        }
    }

    private static CipherEntry getEntry(String type) {
        for (int i = 0; i < ciphers.size(); i++) {
            CipherEntry ce = (CipherEntry) ciphers.elementAt(i);
            if (ce.type.equals(type)) {
                return ce;
            }
        }
        throw new IllegalArgumentException("Unkown algorithm " + type);
    }

    public static int getBlockSize(String type) {
        CipherEntry ce = getEntry(type);
        return ce.blocksize;
    }

    public static int getKeySize(String type) {
        CipherEntry ce = getEntry(type);
        return ce.keysize;
    }
}
