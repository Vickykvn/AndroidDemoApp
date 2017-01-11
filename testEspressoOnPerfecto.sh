#!/bin/bash

WORKSPACE="$1" # the build workspace directory of the Android project
BUILD_VARIANT="$2" # the filename prefix (i.e. 'app-debug') of the app and test APK binaries
TEST_PACKAGE="$3" # the Java package name of the tests (e.g. 'com.example.perfecto.tipcalculator.test')
PERFECTO_CLOUD="$4" # the domain name of the Perfecto cloud being used to run the Espresso tests
PERFECTO_USERNAME="$5" # the username of an account with rights to execute the Espresso tests
PERFECTO_PASSWORD="$6" # the password of an account with rights to execute the Espresso tests
REPOSITORY_PATH="$7"
MAX_DEVICES="$8"

APP_NAME="$BUILD_VARIANT.apk"
APP_FILEPATH="$WORKSPACE/app/build/outputs/apk/$APP_NAME"
TEST_NAME="$BUILD_VARIANT-androidTest.apk"
TEST_FILEPATH="$WORKSPACE/app/build/outputs/apk/$TEST_NAME"
API_SVCS_URL="https://$PERFECTO_CLOUD/services/"

EXIT_CODE=5500 # unhandled
reNumeric='^[0-9]+$'


if ! [[ $MAX_DEVICES =~ $reNumeric ]] ; then
   MAX_DEVICES=1
fi

function err_handler() {
  exit $1
}


if [[ $PERFECTO_PASSWORD == "." ]]
then
  read -s -p "Enter your Perfecto password: " PERFECTO_PASSWORD
fi
clear

# verify that the app APK exists
if [ ! -f $APP_FILEPATH ]
then
  echo "Could not find app binary: $APP_FILEPATH" >&2
  err_handler 1
fi
# verify that the Espresso test APK exists
if [ ! -f $TEST_FILEPATH ]
then
  echo "Could not find test binary: $TEST_FILEPATH" >&2
  err_handler 2
fi

echo "Beginning main workflow..."

# upload to Perfecto cloud through API
echo "Uploading artifacts to cloud repository..."
RESP=$(curl -s -N -X PUT "$API_SVCS_URL/repositories/media/$APP_NAME?operation=upload&user=$PERFECTO_USERNAME&password=$PERFECTO_PASSWORD&overwrite=true&responseFormat=xml" --data-binary @$APP_FILEPATH)
if [[ $RESP != *"Success"* ]]
then
  echo "Failed to upload $APP_FILEPATH to Perfecto repository."
  echo "$RESP"
  err_handler 3
fi
echo "Uploaded $APP_NAME to Perfecto repository."

RESP=$(curl -s -N -X PUT "$API_SVCS_URL/repositories/media/$TEST_NAME?operation=upload&user=$PERFECTO_USERNAME&password=$PERFECTO_PASSWORD&overwrite=true&responseFormat=xml" --data-binary @$TEST_FILEPATH)
if [[ $RESP != *"Success"* ]]
then
  echo "Failed to upload $TEST_FILEPATH to Perfecto repository."
  echo "$RESP"
  err_handler 4
fi
echo "Uploaded $TEST_NAME to Perfecto repository."

# run Espresso test - each is its own execution
echo "Executing Espresso tests..."

function waitUntilFileClosed() {
  local filepath=$1
  while [[ "$(fuser $filepath)" ]]; do sleep 1; done
}

function async_execute() {
  local iterator=$1
  local EXIT_CODES=$2
  local resp_s
  local exit_f=5500
  local EXECUTION_ID
  local HANDSET_ID

  local tmpfile="/tmp/pResp.XXXXXXXXXXXXXXXX"
  if [ ! -f $tmpfile ]
  then
    tmpfile=$(mktemp /tmp/pResp.XXXXXXXXXXXXXXXX)
  fi
  local tmpcmdf=$tmpfile".py"

  ## obtain a new execution
  curl -s -N "$API_SVCS_URL/executions?operation=start&user=$PERFECTO_USERNAME&password=$PERFECTO_PASSWORD&responseFormat=json" > "$tmpfile"
  waitUntilFileClosed "$tmpfile"
  resp_s=$(cat $tmpfile)
  if [[ $resp_s != *"executionId"* ]]
  then
    echo "Failed to obtain a new execution."
    echo "$resp_s"
    exit_f=5
  fi
  echo "import sys, json; print json.load(open(\""$tmpfile"\"))[\"executionId\"]" > $tmpcmdf
  EXECUTION_ID=$(python $tmpcmdf)
  echo "import sys, json; print json.load(open(\""$tmpfile"\"))[\"reportKey\"]" > $tmpcmdf
  REPORT_KEY=$(python $tmpcmdf)
  echo "import sys, json; print json.load(open(\""$tmpfile"\"))[\"singleTestReportUrl\"]" > $tmpcmdf
  REPORT_URL=$(python $tmpcmdf)
  echo "Report Key: "$REPORT_KEY
  echo "{ 'reportUrl' : '$REPORT_URL' }"

  if ! [[ -z "${EXECUTION_ID// }" ]]
  then
  # select device
    curl -s -N "$API_SVCS_URL/handsets?operation=list&user=$PERFECTO_USERNAME&password=$PERFECTO_PASSWORD&status=Connected&inUse=false&os=Android&responseFormat=xml" > "$tmpfile"
    waitUntilFileClosed "$tmpfile"
    echo "import sys; import xml.etree.ElementTree as ET; print ET.parse(\""$tmpfile"\").getroot().findall(\"handset\")[0].find(\"deviceId\").text" > $tmpcmdf
    HANDSET_ID=$(python $tmpcmdf)
    if [[ ${#HANDSET_ID} == 0 ]]
    then
      echo "Failed to find a suitable device."
      cat $tmpfile
      exit_f=6
    fi
    echo "Found device $HANDSET_ID"
  fi

  if ! [[ -z "${HANDSET_ID// }" ]]
  then
    ## open the device
    echo "Allocating device $HANDSET_ID..."
    curl -s -N "$API_SVCS_URL/executions/$EXECUTION_ID?operation=command&user=$PERFECTO_USERNAME&password=$PERFECTO_PASSWORD&command=device&subcommand=open&param.deviceId=$HANDSET_ID" > "$tmpfile"
    waitUntilFileClosed "$tmpfile"
    echo "import sys, json; print json.load(open(\""$tmpfile"\"))[\"flowEndCode\"]" > $tmpcmdf
    local OPEN_STATUS=$(python $tmpcmdf)
    if [[ $OPEN_STATUS == "SUCCEEDED" ]]
    then
      HANDSET_ID=$HANDSET_ID
    else
      exit_f=7
    fi

    echo "async execute on handset: " $HANDSET_ID
    curl -s -N "$API_SVCS_URL/executions/$EXECUTION_ID?operation=command&user=$PERFECTO_USERNAME&password=$PERFECTO_PASSWORD&command=espresso&subcommand=execute&param.handsetId=$HANDSET_ID&param.testPackage=$TEST_PACKAGE&param.debugApp=$APP_NAME&param.testApp=$TEST_NAME&param.failOnError=True&param.reportFormat=Raw&responseFormat=json" > "$tmpfile"
    sleep 1
    waitUntilFileClosed "$tmpfile"
    echo "import sys, json; print json.load(open(\""$tmpfile"\"))[\"flowEndCode\"]" > $tmpcmdf
    local RESULT_CODE=$(python $tmpcmdf)
    echo "import sys, json; print json.load(open(\""$tmpfile"\"))[\"description\"]" > $tmpcmdf
    local RESULT_DESCRIPTION=$(python $tmpcmdf)
    if [[ $RESULT_CODE == "SUCCEEDED" ]]
    then
      echo "Espresso tests passed perfectly on handset $HANDSET_ID!"
      rm "$tmpfile"
      exit_f=0 #complete success
    else
      echo "Failed to execute Espresso tests on handset $HANDSET_ID."
      echo "$RESULT_DESCRIPTION"
      exit_f=8
    fi

    ## close the device
    echo "Closing device..."
    curl -s -N "$API_SVCS_URL/executions/$EXECUTION_ID?operation=command&user=$PERFECTO_USERNAME&password=$PERFECTO_PASSWORD&command=device&subcommand=close&param.deviceId=$HANDSET_ID" > "$tmpfile"
    waitUntilFileClosed "$tmpfile"
    echo "import sys, json; print json.load(open(\""$tmpfile"\"))[\"flowEndCode\"]" > $tmpcmdf
    local CLOSE_STATUS=$(python $tmpcmdf)
  fi

  if ! [[ -z "${EXECUTION_ID// }" ]]
  then
    ## end execution
    echo "Finalizing execution $EXECUTION_ID"
    curl -s -N "$API_SVCS_URL/executions/$EXECUTION_ID?operation=end&user=$PERFECTO_USERNAME&password=$PERFECTO_PASSWORD" > "$tmpfile"
  fi

  rm "$tmpfile"

  echo -e "$exit_f" >> $EXIT_CODES

  return $exit_f
}

EXIT_CODES="/tmp/tmp.log"
rm $EXIT_CODES 2>/dev/null
for ((i=0; i<$MAX_DEVICES; i++)); do
  async_execute $i $EXIT_CODES &
done

wait

waitUntilFileClosed "$EXIT_CODES"

arr=()
lines=$(cat $EXIT_CODES)
echo ${lines[0]}
for line in $lines; do
   arr+=("$line")
done

echo "finalizing ${#arr[@]}"
if [[ ${#arr[@]} -gt 0 ]]; then
  EXIT_CODE=0
  for ((i=0; i<${#arr[@]}; i++)); do
    if ! [[ $arr[$i] == "0" ]]; then
      EXIT_CODE=${arr[$i]}
    fi
  done
fi
echo "after parallel executes, EXIT_CODE is $EXIT_CODE"

rm "$EXIT_CODES"

exit $EXIT_CODE
