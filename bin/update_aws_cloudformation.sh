#!/bin/sh
#
# See common-aws.sh for inputs
#
# Parameters:
# 	See common-aws.sh for inputs
#
# Variables:
#	SKIP_MISSING=[true|false]
#	SKIP_STACK_PREAMBLE_OUTPUTS_CHECK=[true|false]
#
# Requires:
#	common-aws.sh

set -e

BASE_DIR="`dirname \"$0\"`"

# Run common AWS Cloudformation parts
. "$BASE_DIR/common-aws.sh"

aws_change_set(){
	local stack_name="$1"
	local stack_url="$2"
	local stack_outputs="$3"
	local stack_parameters="$4"
	local template_option="${5:---template-body}"
	local update_validate="${6:-update}"

	[ -z "$stack_name" ] && FATAL 'No stack name provided'
	[ -z "$stack_url" ] && FATAL 'No stack url provided'
	[ -z "$stack_outputs" ] && FATAL 'No stack output filename provided'

	# Urgh!
	if [ -n "$stack_parameters" -a -f "$stack_parameters" ]; then

		findpath stack_parameters "$stack_parameters"
		local aws_opts="--parameters '`cat \"$stack_parameters\"`'"
	fi

	shift 3

	local change_set_name="$stack_name-changeset-`date +%s`"

	if [ x"$update_validate" = x"validate" ]; then
		INFO "Validating Cloudformation template: $stack_url"
		"$AWS_CLI" cloudformation validate-template $template_option "$stack_url"

		return $?
	fi

	if check_cloudformation_stack "$stack_name"; then
		local stack_arn="`\"$AWS_CLI\" --output text --query \"StackSummaries[?StackName == '$stack_name'].StackId\" cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE`"
	fi

	if [ -z "$stack_arn" ]; then
		[ x"$SKIP_MISSING" = x"true" ] && log_level='WARN' || log_level='FATAL'

		$log_level "Stack does not exist"

		return 0
	fi

	INFO "Creating Cloudformation stack change set: $stack_name"
	INFO 'Changeset details:'
	sh -c "'$AWS_CLI' cloudformation create-change-set \
		--stack-name '$stack_arn' \
		--change-set-name '$change_set_name' \
		--capabilities CAPABILITY_IAM \
		--capabilities CAPABILITY_NAMED_IAM \
		$template_option '$stack_url' \
		$aws_opts"

	# Changesets only have three states: CREATE_IN_PROGRESS, CREATE_COMPLETE & FAILED.
	INFO "Waiting for Cloudformation changeset to be created: $change_set_name"
	"$AWS_CLI" cloudformation wait change-set-create-complete --stack-name "$stack_arn" --change-set-name "$change_set_name" >/dev/null 2>&1 || :

	INFO 'Checking changeset status'
	if "$AWS_CLI" --output text --query \
		"Status == 'CREATE_COMPLETE' && ExecutionStatus == 'AVAILABLE'" \
		cloudformation describe-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name" | grep -Eq '^True$'; then

		INFO 'Stack change set details:'
		"$AWS_CLI" cloudformation describe-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name"

		INFO "Starting Cloudformation changeset: $change_set_name"
		"$AWS_CLI" cloudformation execute-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name"

		INFO 'Waiting for Cloudformation stack to finish creation'
		"$AWS_CLI" cloudformation wait stack-update-complete --stack-name "$stack_arn" || FATAL 'Cloudformation stack changeset failed to complete'

		local stack_changes=1
	elif "$AWS_CLI" --output text --query "StatusReason == 'The submitted information didn"\\\'"t contain changes. Submit different information to create a change set.'" \
		cloudformation describe-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name" | grep -Eq '^True$'; then

		WARN "Changeset did not contain any changes: $change_set_name"

		WARN "Deleting empty changeset: $change_set_name"
		"$AWS_CLI" cloudformation delete-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name"
	else
		WARN "Changeset failed to create"
		"$AWS_CLI" cloudformation describe-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name"

		WARN "Deleting failed changeset: $change_set_name"
		"$AWS_CLI" cloudformation delete-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name"
	fi


	if [ x"$UPDATE_OUTPUTS" = x"true" -o -n "$stack_changes" -o ! -f "$stack_outputs" ]; then
		parse_aws_cloudformation_outputs "$stack_arn" >"$stack_outputs"

		NEW_OUTPUTS=1
	fi

	return 0
}


if [ -f "$STACK_PREAMBLE_OUTPUTS" ] && [ -z "$SKIP_STACK_PREAMBLE_OUTPUTS_CHECK" -o x"$SKIP_STACK_PREAMBLE_OUTPUTS_CHECK" = x"false" ]; then
	[ -f "$STACK_PREAMBLE_OUTPUTS" ] || FATAL "Existing stack preamble outputs do exist: '$STACK_PREAMBLE_OUTPUTS'"
fi

validate_json_files $STACK_PREAMBLE_FILE $STACK_FILES $STACK_TEMPLATES_FILES $STACK_LOCAL_FILES_COMMON $STACK_LOCAL_FILES_DEPLOYMENT

INFO 'Loading AWS outputs'
load_outputs "$STACK_OUTPUTS_DIR"

if [ -n "$aws_region" ]; then
	INFO "Checking if we need to update AWS region to $aws_region"
	export AWS_DEFAULT_REGION="$aws_region"
else
	WARN "Unable to find region from previous stack outputs"
fi


if [ ! -f "$STACK_PREAMBLE_OUTPUTS" ] && ! stack_exists "$DEPLOYMENT_NAME-preamble"; then
	FATAL "Preamble stack does not exist, do you need to run create_aws_cloudformation.sh first?"
fi

aws_change_set "$DEPLOYMENT_NAME-preamble" "$STACK_PREAMBLE_URL" "$STACK_PREAMBLE_OUTPUTS"


INFO 'Parsing preamble outputs'
. "$STACK_PREAMBLE_OUTPUTS"

INFO 'Copying templates to S3'
"$AWS_CLI" s3 sync "$CLOUDFORMATION_DIR/" "s3://$templates_bucket_name" --exclude '*' --include "$AWS_CONFIG_PREFIX-*.json" --include 'Templates/*.json' --delete

if [ -n "$STACK_LOCAL_FILES_COMMON" -o -n "$STACK_LOCAL_FILES_DEPLOYMENT" ]; then
	INFO 'Copying local Cloudformation templates'
	for _f in $STACK_LOCAL_FILES_COMMON $STACK_LOCAL_FILES_DEPLOYMENT; do
		"$AWS_CLI" s3 cp $_f "s3://$templates_bucket_name/"
	done
fi

# Now we can set the main stack URL
STACK_MAIN_URL="$templates_bucket_http_url/$STACK_MAIN_FILENAME"

for _action in validate update; do
	for stack_full_filename in $STACK_FILES $STACK_LOCAL_FILES_COMMON $STACK_LOCAL_FILES_DEPLOYMENT; do
		STACK_FILENAME="`basename $stack_full_filename`"
		STACK_NAME="`stack_file_name "$DEPLOYMENT_NAME" "$STACK_FILENAME"`"
		STACK_PARAMETERS="$STACK_PARAMETERS_DIR/parameters-$STACK_NAME.$STACK_PARAMETERS_SUFFIX"
		STACK_URL="$templates_bucket_http_url/$STACK_FILENAME"
		STACK_OUTPUTS="$STACK_OUTPUTS_DIR/outputs-$STACK_NAME.$STACK_OUTPUTS_SUFFIX"

		if [ x"$_action" = x"update" ]; then
			INFO "Checking any existing parameters for $STACK_NAME"
			check_existing_parameters "$stack_full_filename"

			if [ -f "$STACK_PARAMETERS" ]; then
				INFO "Checking if we need to update $STACK_NAME parameters"
				update_parameters_file "$stack_full_filename" "$STACK_PARAMETERS"
			else
                		INFO "Generating Cloudformation parameters JSON file for '$STACK_NAME': $STACK_PARAMETERS"
				generate_parameters_file "$stack_full_filename" >"$STACK_PARAMETERS"
			fi
		fi

		aws_change_set "$STACK_NAME" "$STACK_URL" "$STACK_OUTPUTS" "$STACK_PARAMETERS" --template-url $_action || FATAL "Failed to $_action stack: $STACK_NAME, $stack_file"
	done
done

if [ -n "$NEW_OUTPUTS" ]; then
	INFO 'Configuring DNS settings'
	load_outputs "$STACK_OUTPUTS_DIR"
	calculate_dns "$vpc_cidr" >"$STACK_OUTPUTS_DIR/outputs-dns.$STACK_OUTPUTS_SUFFIX"
fi

post_deploy_scripts aws

INFO 'AWS Deployment Update Complete'
