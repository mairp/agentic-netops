FROM localhost:5000/sonic-vs:202605@sha256:097d1551398223969624a8095b37e60351b1629845c1e62e1f437decc1fb873b
COPY telemetry /usr/sbin/telemetry
COPY schema /usr/sbin/schema
COPY boost-libs/libboost_thread.so.1.74.0 /usr/lib/x86_64-linux-gnu/libboost_thread.so.1.74.0
COPY boost-libs/libboost_system.so.1.74.0 /usr/lib/x86_64-linux-gnu/libboost_system.so.1.74.0
COPY telemetry.sh /usr/bin/telemetry.sh
COPY telemetry.conf /etc/supervisor/conf.d/telemetry.conf
RUN chmod +x /usr/sbin/telemetry /usr/bin/telemetry.sh && \
    ldd /usr/sbin/telemetry | grep -E 'swsscommon|hiredis|yang|boost|nl|nftnl|python|not found' || true
