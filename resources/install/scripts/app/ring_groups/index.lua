--	Part of FusionPBX
--	Copyright (C) 2010-2017 Mark J Crane <markjcrane@fusionpbx.com>
--	All rights reserved.
--
--	Redistribution and use in source and binary forms, with or without
--	modification, are permitted provided that the following conditions are met:
--
--	1. Redistributions of source code must retain the above copyright notice,
--	   this list of conditions and the following disclaimer.
--
--	2. Redistributions in binary form must repoduce the above copyright
--	   notice, this list of conditions and the following disclaimer in the
--	   documentation and/or other materials provided with the distribution.
--
--	THIS SOFTWARE IS PROVIDED ''AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
--	INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
--	AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
--	AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
--	OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
--	SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
--	INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
--	CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
--	ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
--	POSSIBILITY OF SUCH DAMAGE.
--
--	Contributor(s):
--	Mark J Crane <markjcrane@fusionpbx.com>
--	Luis Daniel Lucio Qurioz <dlucio@okay.com.mx>

--include the log
	local log = require "resources.functions.log".ring_group

--connect to the database
	local Database = require "resources.functions.database";
	dbh = Database.new('system');

--include json library
	local json
	if (debug["sql"]) then
		json = require "resources.functions.lunajson"
	end

--include functions
	require "resources.functions.trim";
	require "resources.functions.explode";
	require "resources.functions.base64";
	require "resources.functions.file_exists";
	require "resources.functions.channel_utils"
	require "resources.functions.format_ringback"

--define the session hangup
	function session_hangup_hook()

		--send info to the log
			--freeswitch.consoleLog("notice","[ring_groups] originate_disposition: " .. session:getVariable("originate_disposition") .. "\n");

		--status
			status = 'answered'

		--run the missed called function
			if (
				session:getVariable("originate_disposition")  == "ALLOTTED_TIMEOUT"
				or session:getVariable("originate_disposition") == "NO_ANSWER"
				or session:getVariable("originate_disposition") == "NO_USER_RESPONSE"
				or session:getVariable("originate_disposition") == "USER_NOT_REGISTERED"
				or session:getVariable("originate_disposition") == "NORMAL_TEMPORARY_FAILURE"
				or session:getVariable("originate_disposition") == "NO_ROUTE_DESTINATION"
				or session:getVariable("originate_disposition") == "USER_BUSY"
				or session:getVariable("originate_disposition") == "RECOVERY_ON_TIMER_EXPIRE"
				or session:getVariable("originate_disposition") == "failure"
				or session:getVariable("originate_disposition") == "ORIGINATOR_CANCEL"
			) then
				--set the status
					status = 'missed'
				--send missed call notification
					missed();
			end

		--send the ring group event
		    event = freeswitch.Event("CUSTOM", "RING_GROUPS");
			event:addHeader("domain_uuid", domain_uuid);
			event:addHeader("domain_name", domain_name);
			event:addHeader("ring_group_uuid", ring_group_uuid);
			event:addHeader("user_uuid", user_uuid);
			event:addHeader("ring_group_name", ring_group_name);
			event:addHeader("ring_group_extension", ring_group_extension);
			event:addHeader("status", status);
			event:addHeader("call_uuid", uuid);
			event:addHeader("caller_id_name", caller_id_name);
			event:addHeader("caller_id_number", caller_id_number);
			event:fire();

	end

--set the hangup hook function
	if (session:ready()) then
		session:setHangupHook("session_hangup_hook");
	end

--get the variables
	if (session:ready()) then
		session:setAutoHangup(false);
		domain_name = session:getVariable("domain_name");
		domain_uuid = session:getVariable("domain_uuid");
		ring_group_uuid = session:getVariable("ring_group_uuid");
		recordings_dir = session:getVariable("recordings_dir");
		sounds_dir = session:getVariable("sounds_dir");
		username = session:getVariable("username");
		dialplan = session:getVariable("dialplan");
		caller_id_name = session:getVariable("caller_id_name");
		caller_id_number = session:getVariable("caller_id_number");
		network_addr = session:getVariable("network_addr");
		ani = session:getVariable("ani");
		aniii = session:getVariable("aniii");
		rdnis = session:getVariable("rdnis");
		destination_number = session:getVariable("destination_number");
		source = session:getVariable("source");
		uuid = session:getVariable("uuid");
		context = session:getVariable("context");
		call_direction = session:getVariable("call_direction");
	end

--default to local if nil
	if (call_direction == nil) then
		call_direction = "local";
	end

--set ring ready
	if (session:ready()) then
		session:execute("ring_ready", "");
	end

--define additional variables
	uuids = "";
	external = "false";

--set the sounds path for the language, dialect and voice
	if (session:ready()) then
		default_language = session:getVariable("default_language");
		default_dialect = session:getVariable("default_dialect");
		default_voice = session:getVariable("default_voice");
		if (not default_language) then default_language = 'en'; end
		if (not default_dialect) then default_dialect = 'us'; end
		if (not default_voice) then default_voice = 'callie'; end
	end

--get record_ext
	record_ext = session:getVariable("record_ext");
	if (not record_ext) then
		record_ext = "wav";
	end

--set the recording path
	recording_archive = recordings_dir .. "/" .. domain_name .. "/archive/" .. os.date("%Y/%b/%d");

--set the recording file
	record_file = recording_archive:gsub("\\", "/") .. "/" .. uuid .. "." .. record_ext

--prepare the api object
	api = freeswitch.API();

--define the session hangup
	--function on_hangup(s,status)
	--	freeswitch.consoleLog("NOTICE","---- on_hangup: "..status.."\n");
	--	error();
	--end

--get the ring group
	ring_group_forward_enabled = "";
	ring_group_forward_destination = "";
	sql = "SELECT r.*, u.user_uuid FROM v_ring_groups as r, v_ring_group_users as u ";
	sql = sql .. "where r.ring_group_uuid = :ring_group_uuid ";
	sql = sql .. "and r.ring_group_uuid = u.ring_group_uuid ";
	local params = {ring_group_uuid = ring_group_uuid};
	status = dbh:query(sql, params, function(row)
		--domain_uuid = row["domain_uuid"];
		user_uuid = row["user_uuid"];
		ring_group_name = row["ring_group_name"];
		ring_group_extension = row["ring_group_extension"];
		ring_group_forward_enabled = row["ring_group_forward_enabled"];
		ring_group_forward_destination = row["ring_group_forward_destination"];
		ring_group_forward_toll_allow = row["ring_group_forward_toll_allow"];
		ring_group_cid_name_prefix = row["ring_group_cid_name_prefix"];
		ring_group_cid_number_prefix = row["ring_group_cid_number_prefix"];
		missed_call_app = row["ring_group_missed_call_app"];
		missed_call_data = row["ring_group_missed_call_data"];
	end);

--set the caller id
	if (session:ready()) then
		if (ring_group_cid_name_prefix ~= nil) then
			session:execute("export", "effective_caller_id_name="..ring_group_cid_name_prefix.."#"..caller_id_name);
		end
		if (ring_group_cid_number_prefix ~= nil) then
			session:execute("export", "effective_caller_id_number="..ring_group_cid_number_prefix..caller_id_number);
		end
	end

--check the missed calls
	function missed()

		--send missed call email
		if (missed_call_app ~= nil and missed_call_data ~= nil) then
			if (missed_call_app == "email") then
				--set the sounds path for the language, dialect and voice
					default_language = session:getVariable("default_language");
					default_dialect = session:getVariable("default_dialect");
					default_voice = session:getVariable("default_voice");
					if (not default_language) then default_language = 'en'; end
					if (not default_dialect) then default_dialect = 'us'; end
					if (not default_voice) then default_voice = 'callie'; end

				--prepare the files
					file_subject = scripts_dir.."/app/missed_calls/resources/templates/"..default_language.."/"..default_dialect.."/email_subject.tpl";
					file_body = scripts_dir.."/app/missed_calls/resources/templates/"..default_language.."/"..default_dialect.."/email_body.tpl";
					if (not file_exists(file_subject)) then
						file_subject = scripts_dir.."/app/missed_calls/resources/templates/en/us/email_subject.tpl";
						file_body = scripts_dir.."/app/missed_calls/resources/templates/en/us/email_body.tpl";
					end

				--prepare the headers
					headers = '{"X-FusionPBX-Domain-UUID":"'..domain_uuid..'",';
					headers = headers..'"X-FusionPBX-Domain-Name":"'..domain_name..'",';
					headers = headers..'"X-FusionPBX-Call-UUID":"'..uuid..'",';
					headers = headers..'"X-FusionPBX-Email-Type":"missed"}';

				--prepare the subject
					local f = io.open(file_subject, "r");
					local subject = f:read("*all");
					f:close();
					subject = subject:gsub("${caller_id_name}", caller_id_name);
					subject = subject:gsub("${caller_id_number}", caller_id_number);
					subject = subject:gsub("${ring_group_name}", ring_group_name);
					subject = subject:gsub("${ring_group_extension}", ring_group_extension);
					subject = subject:gsub("${sip_to_user}", ring_group_name);
					subject = subject:gsub("${dialed_user}", ring_group_extension);
					subject = trim(subject);
					subject = '=?utf-8?B?'..base64.encode(subject)..'?=';

				--prepare the body
					local f = io.open(file_body, "r");
					local body = f:read("*all");
					f:close();
					body = body:gsub("${caller_id_name}", caller_id_name);
					body = body:gsub("${caller_id_number}", caller_id_number);
					body = body:gsub("${ring_group_name}", ring_group_name);
					body = body:gsub("${ring_group_extension}", ring_group_extension);
					body = body:gsub("${sip_to_user}", ring_group_name);
					body = body:gsub("${dialed_user}", ring_group_extension);
					body = body:gsub(" ", "&nbsp;");
					body = body:gsub("%s+", "");
					body = body:gsub("&nbsp;", " ");
					body = body:gsub("\n", "");
					body = body:gsub("\n", "");
					body = body:gsub("'", "&#39;");
					body = body:gsub([["]], "&#34;");
					body = trim(body);

				--send the email
					cmd = "luarun email.lua "..missed_call_data.." "..missed_call_data.." "..headers.." '"..subject.."' '"..body.."'";
					if (debug["info"]) then
						freeswitch.consoleLog("notice", "[missed call] cmd: " .. cmd .. "\n");
					end
					api = freeswitch.API();
					result = api:executeString(cmd);
			end
		end
	end

--process the ring group
	if (ring_group_forward_enabled == "true" and string.len(ring_group_forward_destination) > 0) then
		--forward the ring group
			session:setVariable("toll_allow",ring_group_forward_toll_allow);	
			session:execute("transfer", ring_group_forward_destination.." XML "..context);
	else
		--get the strategy of the ring group, if random, we use random() to order the destinations
			local sql = [[
				SELECT
					r.ring_group_strategy
				FROM
					v_ring_groups as r
				WHERE
					ring_group_uuid = :ring_group_uuid
					AND r.domain_uuid = :domain_uuid
					AND r.ring_group_enabled = 'true'
			]];

			local params = {ring_group_uuid = ring_group_uuid, domain_uuid = domain_uuid};

			assert(dbh:query(sql, params, function(row)
				if (row.ring_group_strategy == "random") then
					if (database["type"] == "mysql") then
						sql_order = 'rand()'
					else
						sql_order = 'random()' --both postgresql and sqlite uses random() instead of rand()
					end
				else
					sql_order='d.destination_delay, d.destination_number asc'
				end
			end));

		--get the ring group destinations
			sql = [[
				SELECT
					r.ring_group_strategy, r.ring_group_timeout_app, r.ring_group_distinctive_ring,
					d.destination_number, d.destination_delay, d.destination_timeout, d.destination_prompt,
					r.ring_group_timeout_data, r.ring_group_cid_name_prefix, r.ring_group_cid_number_prefix, r.ring_group_ringback
				FROM
					v_ring_groups as r, v_ring_group_destinations as d
				WHERE
					d.ring_group_uuid = r.ring_group_uuid
					AND d.ring_group_uuid = :ring_group_uuid
					AND r.domain_uuid = :domain_uuid
					AND r.ring_group_enabled = 'true'
				ORDER BY
					]]..sql_order..[[
			]];
			if debug["sql"] then
				freeswitch.consoleLog("notice", "[ring group] SQL:" .. sql .. "; params:" .. json.encode(params) .. "\n");
			end
			destinations = {};
			x = 1;
			assert(dbh:query(sql, params, function(row)
				if (row.destination_prompt == "1" or row.destination_prompt == "2") then
					prompt = "true";
				end

				local array = explode("@",row.destination_number);
				if (array[2] == nil) then
					-- no @
					leg_domain_name = domain_name;
				else
					leg_domain_name = array[2];
				end
				cmd = "user_exists id ".. row.destination_number .." "..leg_domain_name;
				user_exists = api:executeString(cmd);
				if (user_exists == "true") then
					--add user_exists true or false to the row array
						row['user_exists'] = "true";
					--handle do_not_disturb
						cmd = "user_data ".. row.destination_number .."@" ..leg_domain_name.." var do_not_disturb";
						if (api:executeString(cmd) ~= "true") then
							--add the row to the destinations array
							destinations[x] = row;
						end
				else
					--set the values
						external = "true";
						row['user_exists'] = "false";
					--add the row to the destinations array
						destinations[x] = row;
				end
				row['domain_name'] = leg_domain_name;
				x = x + 1;
			end));
			--freeswitch.consoleLog("NOTICE", "[ring_group] external "..external.."\n");

		--get the dialplan data and save it to a table
			if (external) then
				sql = [[select * from v_dialplans as d, v_dialplan_details as s
					where (d.domain_uuid = :domain_uuid or d.domain_uuid is null)
					and d.app_uuid = '8c914ec3-9fc0-8ab5-4cda-6c9288bdc9a3'
					and d.dialplan_enabled = 'true'
					and d.dialplan_uuid = s.dialplan_uuid
					order by
					d.dialplan_order asc,
					d.dialplan_name asc,
					d.dialplan_uuid asc,
					s.dialplan_detail_group asc,
					CASE s.dialplan_detail_tag
					WHEN 'condition' THEN 1
					WHEN 'action' THEN 2
					WHEN 'anti-action' THEN 3
					ELSE 100 END,
					s.dialplan_detail_order asc
				]];
				params = {domain_uuid = domain_uuid};
				if debug["sql"] then
					freeswitch.consoleLog("notice", "[ring group] SQL:" .. sql .. "; params:" .. json.encode(params) .. "\n");
				end
				dialplans = {};
				x = 1;
				assert(dbh:query(sql, params, function(row)
					dialplans[x] = row;
					x = x + 1;
				end));
			end

		--process the destinations
			x = 0;
			for key, row in pairs(destinations) do
				--set the values from the database as variables
					user_exists = row.user_exists;
					ring_group_strategy = row.ring_group_strategy;
					ring_group_timeout_app = row.ring_group_timeout_app;
					ring_group_timeout_data = row.ring_group_timeout_data;
					ring_group_cid_name_prefix = row.ring_group_cid_name_prefix;
					ring_group_cid_number_prefix = row.ring_group_cid_number_prefix;
					ring_group_distinctive_ring = row.ring_group_distinctive_ring;
					ring_group_ringback = row.ring_group_ringback;
					destination_number = row.destination_number;
					destination_delay = row.destination_delay;
					destination_timeout = row.destination_timeout;
					destination_prompt = row.destination_prompt;
					domain_name = row.domain_name;

				--set ringback
					ring_group_ringback = format_ringback(ring_group_ringback);
					session:setVariable("ringback", ring_group_ringback);
					session:setVariable("transfer_ringback", ring_group_ringback);

				--setup the delimiter
					delimiter = ",";
					if (ring_group_strategy == "rollover") then
						delimiter = "|";
					end
					if (ring_group_strategy == "sequence") then
						delimiter = "|";
					end
					if (ring_group_strategy == "random") then
						delimiter = "|";
					end
					if (ring_group_strategy == "simultaneous") then
						delimiter = ",";
					end
					if (ring_group_strategy == "enterprise") then
						delimiter = ":_:";
					end

				--leg delay settings
					if (ring_group_strategy == "enterprise") then
						delay_name = "originate_delay_start";
						destination_delay = destination_delay * 1000;
					else
						delay_name = "leg_delay_start";
					end

				--create a new uuid and add it to the uuid list
					new_uuid = api:executeString("create_uuid");
					if (string.len(uuids) == 0) then
						uuids = new_uuid;
					else
						uuids = uuids ..",".. new_uuid;
					end
					session:execute("set", "uuids="..uuids);

				--export the ringback
					if (ring_group_distinctive_ring ~= nil) then
						ring_group_distinctive_ring = ring_group_distinctive_ring:gsub("${local_ip_v4}", session:getVariable("local_ip_v4"));
						ring_group_distinctive_ring = ring_group_distinctive_ring:gsub("${domain_name}", session:getVariable("domain_name"));
						session:execute("export", "sip_h_Alert-Info="..ring_group_distinctive_ring);
					end

				--set confirm
					if (ring_group_strategy == "simultaneous"
						or ring_group_strategy == "sequence"
						or ring_group_strategy == "rollover") then
							session:execute("set", "group_confirm_key=exec");
							session:execute("set", "group_confirm_file=lua ".. scripts_dir:gsub('\\','/') .."/confirm.lua");
					end

				--determine confirm prompt
					if (destination_prompt == nil) then
						group_confirm = "confirm=false,";
					elseif (destination_prompt == "1") then
						group_confirm = "group_confirm_key=exec,group_confirm_file=lua ".. scripts_dir:gsub('\\','/') .."/confirm.lua,confirm=true,";
					elseif (destination_prompt == "2") then
						group_confirm = "group_confirm_key=exec,group_confirm_file=lua ".. scripts_dir:gsub('\\','/') .."/confirm.lua,confirm=true,";
					else
						group_confirm = "confirm=false,";
					end

				--get user_record value and determine whether to record the session
					cmd = "user_data ".. destination_number .."@"..domain_name.." var user_record";
					user_record = trim(api:executeString(cmd));
					--set the record_session variable
					record_session = false;
					if (user_record == "all") then
						record_session = true;
					end
					if (user_record == "inbound" and call_direction == "inbound") then
						record_session = true;
					end
					if (user_record == "outbound" and call_direction == "outbound") then
						record_session = true;
					end
					if (user_record == "local" and call_direction == "local") then
						record_session = true;
					end

				--record the session
					if (record_session) then
						record_session = ",api_on_answer='uuid_record "..uuid.." start ".. record_file .. "'";
					else
						record_session = ""
					end
					row.record_session = record_session

				--process according to user_exists, sip_uri, external number
					if (user_exists == "true") then
						--get the extension_uuid
						cmd = "user_data ".. destination_number .."@"..domain_name.." var extension_uuid";
						extension_uuid = trim(api:executeString(cmd));
						--send to user
						local dial_string_to_user = "[sip_invite_domain="..domain_name..",call_direction="..call_direction..","..group_confirm.."leg_timeout="..destination_timeout..","..delay_name.."="..destination_delay..",dialed_extension=" .. row.destination_number .. ",extension_uuid="..extension_uuid .. row.record_session .. "]user/" .. row.destination_number .. "@" .. domain_name;
							dial_string = dial_string_to_user;
					elseif (tonumber(destination_number) == nil) then
						--sip uri
						dial_string = "[sip_invite_domain="..domain_name..",call_direction="..call_direction..","..group_confirm.."leg_timeout="..destination_timeout..","..delay_name.."="..destination_delay.."]" .. row.destination_number;
					else
						--external number
						y = 0;
						dial_string = '';
						previous_dialplan_uuid = '';
						regex_match = false;
						for k, r in pairs(dialplans) do
							if (y > 0) then
								if (previous_dialplan_uuid ~= r.dialplan_uuid) then
									regex_match = false;
									bridge_match = false;
									square = square .. "]";
									y = 0;
								end
							end
							if (r.dialplan_detail_tag == "condition") then
								if (r.dialplan_detail_type == "destination_number") then
									if (api:execute("regex", "m:~"..destination_number.."~"..r.dialplan_detail_data) == "true") then
										--get the regex result
											destination_result = trim(api:execute("regex", "m:~"..destination_number.."~"..r.dialplan_detail_data.."~$1"));
										--set match equal to true
											regex_match = true
									end
								end
							end
							if (r.dialplan_detail_tag == "action") then
								if (regex_match) then
									--replace $1
										dialplan_detail_data = r.dialplan_detail_data:gsub("$1", destination_result);
									--if the session is set then process the actions
										if (y == 0) then
											square = "[domain_name="..domain_name..",domain_uuid="..domain_uuid..",sip_invite_domain="..domain_name..",call_direction=outbound,"..group_confirm.."leg_timeout="..destination_timeout..","..delay_name.."="..destination_delay..",ignore_early_media=true,";
										end
										if (r.dialplan_detail_type == "set") then
											--session:execute("eval", dialplan_detail_data);
											if (dialplan_detail_data == "sip_h_X-accountcode=${accountcode}") then
												if (session) then
													accountcode = session:getVariable("accountcode");
													if (accountcode) then
														square = square .. "sip_h_X-accountcode="..accountcode..",";
													end
												end
											elseif (dialplan_detail_data == "effective_caller_id_name=${outbound_caller_id_name}") then
											elseif (dialplan_detail_data == "effective_caller_id_number=${outbound_caller_id_number}") then
											else
												square = square .. dialplan_detail_data..",";
											end
										elseif (r.dialplan_detail_type == "bridge") then
											if (bridge_match) then
												dial_string = dial_string .. delimiter .. square .."]"..dialplan_detail_data;
												square = "[";
											else
												dial_string = square .."]"..dialplan_detail_data;
											end
											bridge_match = true;
											break;
										end
									--increment the value
										y = y + 1;
								end
							end
							previous_dialplan_uuid = r.dialplan_uuid;
						end
					end

				--add a delimiter between destinations
					if (dial_string ~= nil) then
						--freeswitch.consoleLog("notice", "[ring group] dial_string: " .. dial_string .. "\n");
						if (x == 0) then
							if (ring_group_strategy == "enterprise") then
								app_data = dial_string;
							else
								app_data = "{ignore_early_media=true}"..dial_string;
							end
						else
							if (app_data == nil) then
								if (ring_group_strategy == "enterprise") then
									app_data = dial_string;
								else
									app_data = "{ignore_early_media=true}"..dial_string;
								end
							else
								app_data = app_data .. delimiter .. dial_string;
							end
						end
					end

				--increment the value of x
					x = x + 1;
			end

		--session execute
			if (session:ready()) then
				--set the variables
					session:execute("set", "hangup_after_bridge=true");
					session:execute("set", "continue_on_fail=true");

				-- support conf-xfer feature
				-- do
				-- 	local uuid = api:executeString("create_uuid")
				-- 	session:execute("export", "conf_xfer_number=xfer-" .. uuid .. "-" .. domain_name)
				-- end
				--set bind digit action
					local bind_target = 'peer'
					if session:getVariable("sip_authorized") == "true" then
						bind_target = 'both';
					end
					local bindings = {
						"local,*1,exec:execute_extension,dx XML " .. context,
						"local,*2,exec:record_session," .. record_file,
						"local,*3,exec:execute_extension,cf XML " .. context,
						"local,*4,exec:execute_extension,att_xfer XML " .. context,
						-- "local,*0,exec:execute_extension,conf_xfer_from_dialplan XML conf-xfer@" .. context
					}
					for _, str in ipairs(bindings) do
						session:execute("bind_digit_action", str .. "," .. bind_target)
					end
					session:execute("digit_action_set_realm", "local");

					--if the user is busy rollover to the next destination
						if (ring_group_strategy == "rollover") then
							x = 0;
							for key, row in pairs(destinations) do
								--set the values from the database as variables
									user_exists = row.user_exists;
									destination_number = row.destination_number;
									domain_name = row.domain_name;

								--get the extension_uuid
									if (user_exists == "true") then
										cmd = "user_data ".. destination_number .."@"..domain_name.." var extension_uuid";
										extension_uuid = trim(api:executeString(cmd));
									end

								--set the timeout
									session:execute("set", "call_timeout="..row.destination_timeout);

								--if the timeout was reached go to the timeout action
									if (x > 0) then
										if (session:getVariable("originate_disposition") == "ALLOTTED_TIMEOUT"
											or session:getVariable("originate_disposition") == "NO_ANSWER"
											or session:getVariable("originate_disposition") == "NO_USER_RESPONSE") then
												break;
										end
									end

								--send the call to the destination
									if (user_exists == "true") then
										dial_string = "["..group_confirm.."sip_invite_domain="..domain_name..",call_direction="..call_direction..",dialed_extension=" .. destination_number .. ",extension_uuid="..extension_uuid..",domain_name="..domain_name..",domain_uuid="..domain_uuid..row.record_session.."]user/" .. destination_number .. "@" .. domain_name;
										session:execute("bridge", dial_string);
									elseif (tonumber(destination_number) == nil) then
										--sip uri
										dial_string = "["..group_confirm.."sip_invite_domain="..domain_name..",call_direction=outbound,domain_name="..domain_name..",domain_uuid="..domain_uuid.."]" .. destination_number;
										session:execute("bridge", dial_string);
									else
										dial_string = "["..group_confirm.."sip_invite_domain="..domain_name..",domain_name="..domain_name..",domain_uuid="..domain_uuid..",call_direction=outbound]loopback/" .. destination_number;
										session:execute("bridge", dial_string);
									end

								--increment the value of x
									x = x + 1;
							end
						end

					--execute the bridge
						if (app_data ~= nil) then
							if (ring_group_strategy == "enterprise") then
								app_data = app_data:gsub("%[", "{");
								app_data = app_data:gsub("%]", "}");
							end
							freeswitch.consoleLog("NOTICE", "[ring group] app_data: "..app_data.."\n");
							-- log.noticef("bridge begin: originate_disposition:%s answered:%s ready:%s bridged:%s", session:getVariable("originate_disposition"), session:answered() and "true" or "false", session:ready() and "true" or "false", session:bridged() and "true" or "false")
							session:execute("bridge", app_data);
							-- log.noticef("bridge done: originate_disposition:%s answered:%s ready:%s bridged:%s", session:getVariable("originate_disposition"), session:answered() and "true" or "false", session:ready() and "true" or "false", session:bridged() and "true" or "false")
						end

					--timeout destination
						if (app_data ~= nil) then
							if session:ready() and (
								session:getVariable("originate_disposition")  == "ALLOTTED_TIMEOUT"
								or session:getVariable("originate_disposition") == "NO_ANSWER"
								or session:getVariable("originate_disposition") == "NO_USER_RESPONSE"
								or session:getVariable("originate_disposition") == "USER_NOT_REGISTERED"
								or session:getVariable("originate_disposition") == "NORMAL_TEMPORARY_FAILURE"
								or session:getVariable("originate_disposition") == "NO_ROUTE_DESTINATION"
								or session:getVariable("originate_disposition") == "USER_BUSY"
								or session:getVariable("originate_disposition") == "RECOVERY_ON_TIMER_EXPIRE"
								or session:getVariable("originate_disposition") == "failure"
							) then
								--execute the time out action
									session:execute(ring_group_timeout_app, ring_group_timeout_data);
							end
						else
							if (ring_group_timeout_app ~= nil) then
								--execute the time out action
									session:execute(ring_group_timeout_app, ring_group_timeout_data);
							else
								local sql = "SELECT ring_group_timeout_app, ring_group_timeout_data FROM v_ring_groups ";
								sql = sql .. "where ring_group_uuid = :ring_group_uuid";
								local params = {ring_group_uuid = ring_group_uuid};
								if debug["sql"] then
									freeswitch.consoleLog("notice", "[ring group] SQL:" .. sql .. "; params:" .. json.encode(params) .. "\n");
								end
								dbh:query(sql, params, function(row)
									--execute the time out action
										session:execute(row.ring_group_timeout_app, row.ring_group_timeout_data);
								end);
							end
						end
				end
		
		end

--actions
	--ACTIONS = {}
	--table.insert(ACTIONS, {"set", "hangup_after_bridge=true"});
	--table.insert(ACTIONS, {"set", "continue_on_fail=true"});
	--table.insert(ACTIONS, {"bridge", app_data});
	--table.insert(ACTIONS, {ring_group_timeout_app, ring_group_timeout_data});
