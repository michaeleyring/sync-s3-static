#!/bin/bash
echo "sync-s3-static.sh"

# sync-s3-static.#!/bin/sh
# Author: Michael B. Eyring
# 8/26/2018
# Objective: Take a zip output from CodeBuild, and extract and sync to S3.

# Assumptions:
#   1. Zip files are cleaned elsewhere. This assumes one will be present or takes the first only.

# Arguments
#   1 = Input Bucket (source)- The source bucket from CodePipeline or the like
#   2 = Input Folder (source) - The source folder (i.e. codepipeline_bucket/input_folder(s))
#   3 = Output Bucket (Web) - The S3 bucket the output will be sent to (i.e. the static website bucket)
#   4 = [ Optional] Local zip file storage location - The directory on the instance to store the retrieved Zip
#       defaults to /tmp
#   5 = [Optional] Local zip extraction folder location - Where the zip file will be extracted to
#       defaults to /tmp/website

# SUCCESS if we make it to the end
SUCCESS=0
# Not enough arguments passed to the program
ERROR_NOT_ENOUGH_ARG=1
# Error copying zip file from s3 to /tmp directory
ERROR_COPY_ZIP=2
# Error making the directory /tmp/website
ERROR_MKDIR_TMP_WEBSITE=3
# Error unzipping retrieved zip file to extract directory
ERROR_UNZIP=4
# Error removing previous files from zip file extracting point
ERROR_REMOVE_OUTPUT=5
# Error syncing to S3
ERROR_S3_SYNC=6

# Whether or not we cleanup tmp files at end, used for parameter $6
# This is destructive so only do if specifically requested (also helps with debugging if there are issues)
DO_CLEANUP="1"
SKIP_CLEANUP="0"

# Check to see we received the minimum parameters
if [ $# -lt 3 ]; then
  echo "sync-s3-static.sh [Input source bucket] [Input source folder] [Output bucket (web)] [Optional:local zip directory] [Optional:local extract directory] [Optional:Clean]"
  echo "Example:"
  echo "sh synch-s3-static.sh codepipeline-us-east-1-123456789012 qa.testbucket.com folder1/folder2 /tmp /tmp/website clean"
  exit ${ERROR_NOT_ENOUGH_ARGS}
else
  # Store parameter 1 as the input source bucket
  INPUT_BUCKET=$1
  echo "`date` Param 1: INPUT_BUCKET = $INPUT_BUCKET"
  # Store parameter 2 as the input source folder(s)
  # I.e. Troop161_Web/dist (no slash at beginning or end)
  INPUT_FOLDER=$2
  echo "`date` Param 2: INPUT_FOLDER = $INPUT_FOLDER"
  # Store parameter 3 as the output bucket, where things will be synched to
  WEB_BUCKET=$3
  echo "`date` Param 3: WEB_BUCKET = $WEB_BUCKET"
  # The following are optional, use if passed otherwise defaults
  if [ $# -gt 3 ]; then
    DIR_ZIP_FILE_OUTPUT=$4
  else
    DIR_ZIP_FILE_OUTPUT="/tmp"
  fi
  echo "`date` Param 4: DIR_ZIP_FILE_OUTPUT = $DIR_ZIP_FILE_OUTPUT"

  # Assign 5th parameter (or use default). Where the zip file will be extracted to
  if [ $# -gt 4 ]; then
    DIR_ZIP_EXTRACT_OUTPUT=$5
  else
    DIR_ZIP_EXTRACT_OUTPUT="/tmp/website"
  fi
  echo "`date` Param 5: DIR_ZIP_EXTRACT_OUTPUT = $DIR_ZIP_EXTRACT_OUTPUT"

  # Assign 6th parameter (or use default). If we clean up after completion
  if [ $# -gt 5 ]; then
     # if requested, remove output upon completion (zip and zip output)
     if [[ $6 =~ ^(CLEAN$|clean) ]]; then
       CLEAN="$DO_CLEANUP"
     else
       # We will skip the cleanup at the end
       CLEAN="$SKIP_CLEANUP"
     fi
  else
    # destructive action, so only apply if specifically requested
    # default to no cleanup
    CLEAN="$SKIP_CLEANUP"
  fi
  echo "`date` Param  6: CLEAN = $CLEAN"
fi

# Get the file listing. Expecting only one file due to cleanup prior to build step
# Output will appear like this:
# 2018-08-25 21:57:09   17461898 Troop161_Web/dist/75wgIgM.zip
BUCKET_ZIP=$(aws s3 ls s3://$INPUT_BUCKET/$INPUT_FOLDER/ --recursive | awk '{printf $4}')

#  show what we have
echo "`date` File found:$BUCKET_ZIP."

# pull out just the zip file name
ZIP_NAME=$(echo $BUCKET_ZIP | awk 'BEGIN {FS="/"}{print $3}')
# Output what we extracted
echo "`date` Zip file:$ZIP_NAME, extracted from $BUCKET_ZIP name"

# configure for proper signature
aws configure set s3.signature_version s3v4

# copy the zip file to tmp
BUCKET_COPY=$(aws s3 cp s3://$INPUT_BUCKET/$INPUT_FOLDER/$ZIP_NAME $DIR_ZIP_FILE_OUTPUT)
if [ ! $? -eq 0 ]; then
  echo "`date` Error copying $ZIP_NAME to $DIR_ZIP_FILE_OUTPUT"
  exit ${ERROR_COPY_ZIP}
else
  echo "`date` Copy of $ZIP_NAME to $DIR_ZIP_FILE_OUTPUT succesful"
fi

# verify if we have the output directory to extract to
if [ ! -d "$DIR_ZIP_EXTRACT_OUTPUT" ]; then
  # create directory to hold zip contents since it is not present
  mkdir $DIR_ZIP_EXTRACT_OUTPUT

  # alert on failure to create directory and exit
  if [ ! $? -eq 0 ]; then
    echo "`date` Error creating $DIR_ZIP_EXTRACT_OUTPUT to hold zip output"
    exit ${ERROR_MKDIR_TMP_WEBSITE}
  else
    echo "`date` Creation of $DIR_ZIP_EXTRACT_OUTPUT successful"
  fi
else
  # Directory was already present, move on
  echo "`date` Directory $DIR_ZIP_EXTRACT_OUTPUT exists already"
  echo "`date` Removing existing files from $DIR_ZIP_EXTRACT_OUTPUT"

  # Remove existing files in directory
  rm -rf $DIR_ZIP_EXTRACT_OUTPUT
  # Check results
  if [ ! $? -eq 0 ]; then
    echo "`date` Error removing existing files from $DIR_ZIP_EXTRACT_OUTPUT"
    exit ${ERROR_REMOVE_OUTPUT}
  fi
fi

# Extract files from zip file to the directory
unzip -o $DIR_ZIP_FILE_OUTPUT/$ZIP_NAME -d $DIR_ZIP_EXTRACT_OUTPUT

# check the results
if [ ! $? -eq 0 ]; then
  echo "`date` Error unzipping $ZIP_NAME to $DIR_ZIP_EXTRACT_OUTPUT"
  exit ${ERROR_UNZIP}
else
  echo "`date` Unzip operation succesful for $ZIP_NAME"
fi

# sync output to S3
aws --region us-east-1 s3 sync $DIR_ZIP_EXTRACT_OUTPUT s3://$WEB_BUCKET --acl=public-read --delete
# check status of operation
if [ ! $? -eq 0 ]; then
  echo "`date` Error syncing $DIR_ZIP_EXTRACT_OUTPUT to $WEB_BUCKET"
  exit ${ERROR_S3_SYNC}
else
  echo "`date` Sync to S3 of $DIR_ZIP_EXTRACT_OUTPUT to $WEB_BUCKET succesful"
fi

# Cleanup the temp files if requested
# Destructive action so only applied if specifically requested
if [ $CLEAN -eq $DO_CLEANUP ]; then
  # Remove Phase 1: Remove Zip file that was retrieved
  # Remove the zip file we retrieved from the input bucket
  rm $DIR_ZIP_FILE_OUTPUT/$ZIP_NAME
  # check the result of the removal of zip files
  if [ ! $? -eq 0 ]; then
    echo "`date` Error removing retrieved zip file $ZIP_NAME from $DIR_ZIP_FILE_OUTPUT directory"
    exit ${ERROR_REMOVE_OUTPUT}
  else
    echo "`date` Removed $ZIP_NAME from $DIR_ZIP_FILE_OUTPUT"
  fi

  # Remove Phase 2: Remove extracted zip output
  # Remove the files in the extraction directory (from the retreived zip file)
  rm -rf $DIR_ZIP_EXTRACT_OUTPUT/*
  # Check result
  if [ ! $? -eq 0 ]; then
    echo "`date` Error removing extracted files from $DIR_ZIP_EXTRACT_OUTPUT"
    exit ${ERROR_REMOVE_OUTPUT}
  else
    echo "`date` Removed files from $DIR_ZIP_EXTRACT_OUTPUT"
  fi # if there was an error removing extracted zip output
else
  echo "`date` Cleanup was not requested, zip file and output files remain"
fi

# if we made it here, we were succesful
echo "`date` sync-s3-static.sh ompleted"
exit ${SUCCESS}
