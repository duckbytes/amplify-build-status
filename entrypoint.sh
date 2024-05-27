#!/bin/sh -l

set -e

APP_ID=$1
BRANCH_NAME=$2
COMMIT_ID=$3
WAIT=$4
TIMEOUT=$5
NO_FAIL=$6
export AWS_DEFAULT_REGION="$AWS_REGION"

if [[ -z "$AWS_ACCESS_KEY_ID" ]]; then
  echo "You must provide the AWS_ACCESS_KEY_ID environment variable."
  exit 1
fi

if [[ -z "$AWS_SECRET_ACCESS_KEY" ]]; then
  echo "You must provide the AWS_SECRET_ACCESS_KEY environment variable."
  exit 1
fi

if [[ -z "$AWS_DEFAULT_REGION" ]] ; then
  echo "You must provide the AWS_REGION environment variable."
  exit 1
fi

if [[ -z "$APP_ID" ]] ; then
  echo "You must provide the app-id."
  exit 1
fi

if [[ -z "$BRANCH_NAME" ]] ; then
  echo "You must provide the branch-name."
  exit 1
fi

if [[ -z "$COMMIT_ID" ]] ; then
  echo "You must provide the commit-id."
  exit 1
fi

if [[ $TIMEOUT -lt 0 ]]; then
    echo "Timeout must not be a negative number. Use 0 for unlimited timeout."
    exit 1
fi

get_backend_env_name () {
    local env_name;
    local env_arn;
    local next_token="";
    local list_result;
    # get backendEnvironmentArn from get branch first
    env_arn=$(aws amplify get-branch --app-id "$APP_ID" --branch-name "$BRANCH_NAME" | jq -r ".branch.backendEnvironmentArn")
    # search the list of backend environments for the environment name
    while : ; do
        list_result=$(aws amplify list-backend-environments --app-id "$APP_ID" --next-token "$next_token")
        env_name=$(echo $list_result | jq -r ".backendEnvironments[] | select(.backendEnvironmentArn == \"$env_arn\") | .environmentName")
        if [[ -n $env_name ]]; then
            env_name=$(echo $env_name | tr -d " \t\n\r")
            break
        fi
        next_token=$(echo $list_result | jq -r ".nextToken")
        next_token=$(echo $next_token | tr -d " \t\n\r")
        if [[ -z $next_token ]] || [[ $next_token == "null" ]]; then
            break
        fi
    done
    exit_status=$?
    echo "$env_name"
    return $exit_status
}

get_backend_graphql_endpoint () {
    local endpoint;
    local env_name;
    local test;
    env_name=$(get_backend_env_name)
    echo "Found env name getting graphql endpoint: $env_name" >&2
    endpoint=$(aws amplifybackend get-backend --app-id "$APP_ID" --backend-environment-name "$env_name" | jq -r ".AmplifyMetaConfig" | jq -r ".api.platelet.output.GraphQLAPIEndpointOutput")
    exit_status=$?
    endpoint=$(echo $endpoint | tr -d " \t\n\r")
    echo "$endpoint"
    return $exit_status
}


write_output () {
    local env_name;
    local graphql_endpoint;
    echo "status=$STATUS" >> $GITHUB_OUTPUT
    env_name=$(get_backend_env_name)
    graphql_endpoint=$(get_backend_graphql_endpoint)
    echo "Found environment name: $env_name"
    echo "Found graphql endpoint: $graphql_endpoint"
    echo "environment_name=$env_name" >> $GITHUB_OUTPUT
    echo "graphql_endpoint=$graphql_endpoint" >> $GITHUB_OUTPUT
}

get_status () {
    local status;
    status=$(aws amplify list-jobs --app-id "$APP_ID" --branch-name "$BRANCH_NAME" | jq -r ".jobSummaries[] | select(.commitId == \"$COMMIT_ID\") | .status")
    exit_status=$?
    # get only the first line in case there are multiple runs
    status=$(echo $status | head -n 1)
    # it seems like sometimes status ends up with a new line in it?
    # strip it out
    status=$(echo $status | tr -d " \t\n\r")
    echo "$status"
    return $exit_status
}

no_fail_check () {
    if [[ $NO_FAIL == "true" ]]; then
        exit 0
    else
        exit 1
    fi
}

STATUS=$(get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID")

if [[ $? -ne 0 ]]; then
    echo "Failed to get status of the job."
    exit 1
fi

if [[ $STATUS == "SUCCEED" ]]; then
    echo "Build Succeeded!"
    echo $(write_output)
    exit 0
elif [[ $STATUS == "FAILED" ]]; then
    echo "Build Failed!"
    echo $(write_output)
    no_fail_check
fi

count=0

if [[ -z $STATUS ]]; then
    echo "No job found for commit $COMMIT_ID. Waiting for job to start..."
    while [[ -z $STATUS ]]; do
        if [[ $count -ge 1800 ]]; then
            echo "Timed out waiting for job to start."
            exit 1
        fi
        sleep 30
        STATUS=$(get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID")
        if [[ $? -ne 0 ]]; then
            echo "Failed to get status of the job."
            exit 1
        fi
        count=$((count+30))
        echo "Waiting for job to start..."
    done
    elif [[ $STATUS ]]; then
        echo "Build in progress... Status: $STATUS"
    fi

seconds=$(( $TIMEOUT * 60 ))
count=0

if [[ "$WAIT" == "false" ]]; then
    echo $(write_output)
    exit 0
elif [[ "$WAIT" == "true" ]]; then
    while [[ $STATUS != "SUCCEED" ]]; do
        if [[ $TIMEOUT -ne 0 ]] && [[ $count -ge $seconds ]]; then
            echo "Timed out."
            exit 1
        fi
        sleep 30
        STATUS=$(get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID")
        if [[ $? -ne 0 ]]; then
            echo "Failed to get status of the job."
            exit 1
        fi
        if [[ $STATUS == "CANCELLED" ]]; then
            echo "Build cancelled!"
            echo $(write_output)
            no_fail_check
        elif [[ $STATUS == "FAILED" ]]; then
            echo "Build failed!"
            echo $(write_output)
            no_fail_check
        elif [[ $STATUS == "RUNNING" ]] || [[ $STATUS == "PENDING" ]]; then
            echo "Build in progress... Status: $STATUS"
        else
            echo "Unknown status: $STATUS"
            exit 1
        fi
        count=$(( $count + 30 ))
    done
    echo "Build Succeeded!"
    echo $(write_output)
fi
