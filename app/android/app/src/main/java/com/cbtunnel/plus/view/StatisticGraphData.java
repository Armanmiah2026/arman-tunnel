package com.cbtunnel.plus.view;

public final class StatisticGraphData {
    private static final StatisticGraphData INSTANCE = new StatisticGraphData();
    private final DataTransferStats stats = new DataTransferStats();

    private StatisticGraphData() {
    }

    public static StatisticGraphData getStatisticData() {
        return INSTANCE;
    }

    public DataTransferStats getDataTransferStats() {
        return stats;
    }

    public static final class DataTransferStats {
        public void addBytesSent(long bytes) {
        }

        public void addBytesReceived(long bytes) {
        }
    }
}
