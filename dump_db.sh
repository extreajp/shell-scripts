#!/bin/bash

### Get RDS DB dump and manage S3 backets script / @extreajp
# 
# for ubuntu enviroments
# 
# Usage:
#  $ sudo su - ops-user
#  $ git clone https://github.com/extreajp/dump_db.git
#  $ cp -p dump_db/dump_db.sh /path/to/scripts/
#  $ chmod u+x dump_db.sh
#  $ crontab -e
#  ---
#  example) GMT+9(JST)
#  0  * * * * /path/to/scripts/dump_db.sh get 2>&1 | logger -t dump_db.sh -p local0.info
#  15 * * * * /path/to/scripts/dump_db.sh put 2>&1 | logger -t dump_db.sh -p local0.info
#  0  4 * * * /path/to/scripts/dump_db.sh clean 2>&1 | logger -t dump_db.sh -p local0.info
#  ---
#  Options:
#  get:
#      get DB dump file.
#  put:
#      put DB dump files to AWS S3 backets.  
#  clean:
#      delete old DB dump files from S3 backets.
#      *after ${PERIOD_SEC} over.
#  ls_s3:
#      list DB dump files from S3 backets.
#  cp_s3:
#      copy DB dump files to local directory from S3 backets.
###

DB_CONF=/path/to/database.conf #example: databases.yml in redmine
PERIOD_SEC=1296000 # 15days
TMP_PATH=/tmp
TMP_LIST=/tmp/listfile
DUMP_PATH=dump_db
AWS_CMD=/usr/local/bin/aws
AWS_S3_BACKETS=my-s3-backetname
SLACK_WEBHOOKS="https://hooks.slack.com/services/mywebhook_url"
SLACK_EMOJI=":bomb:"
SLACK_USER="ALERT_BOT"
SLACK_TO="@here"

function check_result() {
    if [ $? -ne 0 ]; then
     echo "error: actions $1 failed."
     if [ "$2" = "notify" ] && [ ! -z "$3" ]; then notify_slack "$3" ;fi
     exit 1
    fi
}

function notify_slack() {
     local ALERT_HOST=`uname -n`
     # notify to slack
     curl -s -S -X POST --data-urlencode \
     "payload={\
     \"channel\": \"${SLACK_CH}\", \
     \"username\": \"${SLACK_USER}\", \
     \"icon_emoji\": \"${SLACK_EMOJI}\", \
     \"text\": \"${SLACK_TO} ${ALERT_HOST}: $1\" }" \
     ${SLACK_WEBHOOKS}
}

function dump_db() {
     local CHECK_DB=${DB_TYPE:-mysql2}

     case ${CHECK_DB} in
       "mysql2")
         # for MySQL dump options
         local DB_PORT=3306
         local DB_CMD=/usr/bin/mysqldump
         ${DB_CMD} --single-transaction -u${USER} -h ${RDS_HOST} --password=${PASSWORD} ${DB_NAME} > ${DUMP_FILE}
       ;;
       "postgresql")
         echo "PostgreSQL is still not support."
         exit 1
       ;;
       *)
         echo "${CHECK_DB} is not support."
         exit 1
       esac
}

function puts_usage() {
    cat << HERE
${0##*/}
---
usage)
 ./${0##*/} { get | put | clean | ls_s3 | cp_s3 }

example)
 ./${0##*/} ls_s3
 ./${0##*/} cp_s3 [sql filename]

see also script file's comments.
HERE
    exit 1
}

## MAIN ##

# Read DB access informations.
if [ -f ${DB_CONF} ] && [ ! -z ${DB_CONF} ]; then
  RDS_HOST=`grep host ${DB_CONF} | awk '{print $2}'`
  USER=`grep username ${DB_CONF} | awk '{print $2}'`
  PASSWORD=`grep password ${DB_CONF} | awk '{print $2}' | sed -e 's/"//g'`
  DB_NAME=`grep database ${DB_CONF} | awk '{print $2}'`
  DB_TYPE=`grep adapter ${DB_CONF} | awk '{print $2}'`
else
  echo "can't read database config file."
  exit 1
fi

# Create tmp dir
if [ ! -d ${TMP_PATH}/${DUMP_PATH} ]; then
 mkdir -p --mode 700 ${TMP_PATH}/${DUMP_PATH}
fi

DUMP_FILE=${TMP_PATH}/${DUMP_PATH}/`uname -n`_`date '+%Y-%m-%d-%H-%M-%S'`.sql

case "$1" in 
   "get" )
      cd ${TMP_PATH}
      dump_db 
      check_result $1 notify "can't get DB dump file from ${RDS_HOST}."
  
      chmod 600 ${DUMP_FILE}
      echo "get DB dump completed (${DUMP_FILE})"
   ;;
   "put" )
      cd ${TMP_PATH}
      ${AWS_CMD} s3 sync ${TMP_PATH}/${DUMP_PATH} s3://${AWS_S3_BACKETS}/`uname -n`/${DUMP_PATH} --acl private
      check_result $1 notify "can't put DB dump files to S3"
  
      # Delete tmp files
      if [ -d ${TMP_PATH}/${DUMP_PATH} ]; then
        rm -f ${TMP_PATH}/${DUMP_PATH}/*.sql
        rmdir ${TMP_PATH}/${DUMP_PATH}
      fi
   ;;
   "clean" )
      TIMESTAMP=`date +%s`

      # Get dump list file.
      cd ${TMP_PATH}
      ${AWS_CMD} s3 ls s3://${AWS_S3_BACKETS}/`uname -n`/${DUMP_PATH}/ > ${TMP_LIST}
      check_result $1 notify "can't clean old DB dump files from S3"

      # Delete old sql files.
      while read line;
      do
       FILE_DATE=`echo ${line} | awk '{print $1,"",$2}'`
       FILE_NAME=`echo ${line} | awk '{print $4}' | sed -e 's/.sql//'`
       FILE_TIMESTAMP=`date +%s --date "${FILE_DATE}"`
       DIFF_TIMESTAMP=`expr ${TIMESTAMP} - ${FILE_TIMESTAMP}`
  
      if [ ${DIFF_TIMESTAMP} -ge ${PERIOD_SEC} ] ; then
       echo "${FILE_NAME}: ${DIFF_TIMESTAMP} sec old. delete now." 
       ${AWS_CMD} s3 rm s3://${AWS_S3_BACKETS}/`uname -n`/${DUMP_PATH}/${FILE_NAME}.sql
      fi 
     done < ${TMP_LIST}

     rm ${TMP_LIST}
 ;;
 "ls_s3" )
     cd ${TMP_PATH}
     ${AWS_CMD} s3 ls s3://${AWS_S3_BACKETS}/`uname -n`/${DUMP_PATH}/
     check_result $1
 ;;
 "cp_s3" )
     if [ -z $2 ]; then
      puts_usage
     fi
 
     cd ${TMP_PATH}
     ${AWS_CMD} s3 cp s3://${AWS_S3_BACKETS}/`uname -n`/${DUMP_PATH}/$2 .
     check_result $1
 
     echo "saved DB dump file to ${TMP_PATH}/$2"
  ;;
  *) 
     puts_usage
  ;;
esac
