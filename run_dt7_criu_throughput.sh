#!/bin/bash

export SERVER_INSTALL_DIR="/opt/IBM/openliberty-21.0.0.3"

export SERVER_NAME=dt7

export LOG_MESSAGE="The ${SERVER_NAME} server is ready to run a smarter planet"

export LOG_LOCATION="${SERVER_INSTALL_DIR}/wlp/usr/servers/${SERVER_NAME}/logs/messages.log"

export FIRST_REQUEST_URL="localhost:9082/daytrader/index.faces"

export SNAPSHOT_DIR="${SERVER_INSTALL_DIR}/wlp/usr/servers/${SERVER_NAME}_checkpoint"

export SCC_LOCATION="${SERVER_INSTALL_DIR}/usr/servers/.classCache"

check_server_started() {
    waitPeriod=30
    waited=0
    while [ ${waited} -lt ${waitPeriod} ];
    do
        grep "${LOG_MESSAGE}" "${LOG_LOCATION}" &> /dev/null
                local app_started=$?
                if [ ${app_started} -eq 0 ]; then
                        break
                else
                        sleep 1s
            waited=$(( waited + 1 ))
                fi
        done
    if [ ${waited} -eq ${waitPeriod} ];
    then
        echo "Looks like something went wrong in starting the server!"
        exit 1
    fi
}

pre_test_cleanup() {
    rm -f starttime.out
    if [ ! -z "${LOG_LOCATION}" ]; then
        rm -f ${LOG_LOCATION}
    fi
    rm -f endtime.out
}

pre_test_cleanup_criu() {
    rm -f starttime.out
    rm -f endtime.out
}

create_checkpoint() {
    echo "Creating checkpoint for server ${SERVER_NAME}"
    if [ -d ${SCC_LOCATION} ]; then
        rm -fr ${SCC_LOCATION}
    fi
    if [ -d ${SNAPSHOT_DIR} ]; then
        rm -fr ${SNAPSHOT_DIR}
    fi
    pre_test_cleanup
    mkdir -p ${SNAPSHOT_DIR}
    ./start_server.sh &
    echo "Waiting for server to be started ..."
    check_server_started
    if [ $? -eq 0 ]; then
        numJava=`ps -ef | grep "java" | grep -v grep | wc -l`
        if [ "$numJava" -ne "1" ]; then
            echo "More than one java process found"
            exit 1
        fi
        pid=`ps -ef | grep "java" | grep -v grep | awk '{ print $2 }'`
        if [ -z "${pid}" ]; then
            echo "Failed to find pid of the process to be checkpointed"
            exit 1;
        fi
        echo "Pid to be checkpointed: ${pid}"
        date +"%s.%3N" > cpstart.out
        cmd="./criu-ns dump -t ${pid} --tcp-established --images-dir=${SNAPSHOT_DIR} -j -v4 -o ${SNAPSHOT_DIR}/dump.log"
        echo "CMD: ${cmd}"
        ${cmd}
        date +"%s.%3N" > cpend.out
        start_time=`cat cpstart.out`
        end_time=`cat cpend.out`
        diff=`echo "$end_time-$start_time" | bc`
        echo "Time taken to checkpoint: ${diff} secs"
    fi
    grep "Dumping finished successfully" ${SNAPSHOT_DIR}/dump.log
    if [ $? -ne 0 ]; then
        echo "Checkpoint failed"
        exit 1
    fi
    echo "Checkpoint created"
}

cleanup_snapshot() {
    if [ -d ${SNAPSHOT_DIR} ]; then
        rm -fr ${SNAPSHOT_DIR}
    fi
}

test_server_fr_criu() {
    isColdRun=$1
    echo "Starting ${SERVER_NAME} using checkpoint"
    pre_test_cleanup_criu

    ./hiturlloop.sh &
    ./restore_server.sh &
    while [ ! -f endtime.out ]; do
        sleep 1s
    done
    start_time=`cat starttime.out`
    end_time=`cat endtime.out`
    diff=`echo "$end_time-$start_time" | bc`
    echo "Start time: ${start_time}"
    echo "End time: ${end_time}"
    echo "Response time: ${diff} seconds"
    if [ ${isColdRun} -eq 0 ]; then
        server_fr_criu+=(${diff})
    else
        echo "Ignoring this as cold run"
    fi

        #restore_time=`crit show ${SNAPSHOT_DIR}/stats-restore | grep restore_time | cut -d ':' -f 2 | cut -d ',' -f 1`
        #echo "time to restore: " $((${restore_time}/1000))

    echo -n "Stopping the server ... "
    pid=`ps -ef | grep "java" | grep -v grep | awk '{ print $2 }'`
    kill -9 $pid
    echo "Done"
}

restore_server() {
    echo "Restoring the server ... "
    ./restore_server.sh &
}

apply_load() {
    sleep 10
    /opt/IBM/criu_snapshot/apps/JMeter-3.3/bin/jmeter -n -t /opt/IBM/criu_snapshot/apps/JMeter-3.3/daytrader7.jmx -j /tmp/daytrader.stats.0 -JHOST=localhost -JPORT=9080 -JSTOCKS=9999 -JBOTUID=0 -JTOPUID=14999 -JDURATION=60 -JTHREADS=1
}

stop_server() {
    echo -n "Stopping the server ... "
    pid=`ps -ef | grep "java" | grep -v grep | awk '{ print $2 }'`
    kill -9 $pid

    #./stop_server.sh

    echo "Done"
}


### SCRIPT START ###

export JAVA_HOME=/opt/IBM/criu_snapshot/sdks/jdk8-hotspot


if [ -z ${JAVA_HOME} ]; then
    echo "JAVA_HOME is not set"
    exit 1
fi

echo "Using JAVA_HOME: ${JAVA_HOME}"
export PATH="/opt/IBM/criu_snapshot/criu/criu-3.12/criu:$JAVA_HOME/bin:$JAVA_HOME/jre/bin:$PATH"

# Start DB2
ssh db2inst1@localhost "perl ~/bin/db2dt7.pl --Start"

# Before running criu tests, create a checkpoint
echo "Creatning Snapshot ... "
create_checkpoint
echo "Done Creating Snapshot"

# Restart DB2
ssh db2inst1@localhost "perl ~/bin/db2dt7.pl --Start"

echo "Running Test ... "

# Start the server from the CRIU checkpoint
restore_server

# Jmeter Load
apply_load

# Stop server
stop_server

echo "Done Running Test"

cleanup_snapshot
