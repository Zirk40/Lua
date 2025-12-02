--Copyright (c) 2013~2016, Byrthnoth
--All rights reserved.

--Redistribution and use in source and binary forms, with or without
--modification, are permitted provided that the following conditions are met:

--    * Redistributions of source code must retain the above copyright
--      notice, this list of conditions and the following disclaimer.
--    * Redistributions in binary form must reproduce the above copyright
--      notice, this list of conditions and the following disclaimer in the
--      documentation and/or other materials provided with the distribution.
--    * Neither the name of <addon name> nor the
--      names of its contributors may be used to endorse or promote products
--      derived from this software without specific prior written permission.

--THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
--ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
--WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
--DISCLAIMED. IN NO EVENT SHALL <your name> BE LIABLE FOR ANY
--DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
--(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
--LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
--ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
--(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
--SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.



-----------------------------------------------------------------------------------
--Name: flow_entry(r_line,mob_table)
--Desc: Common entry point to begin GearSwap flow. Finishes building the spell
--      table and is responsible for doing anything that is trigger-agnostic.
--Args:
---- r_line - resource line
---- mob_table - GearSwap amended mob table for the provided target
-----------------------------------------------------------------------------------
--Returns:
---- If unable to fire the action : originally entered command
---- Otherwise : true
-----------------------------------------------------------------------------------
function flow_entry(r_line,mob_table)
    r_line.name = r_line[language] -- Resource redicting should take care of this for us
    local spell = spell_complete(r_line)
    spell.target = mob_table
    spell.action_type = action_type_map[spell.prefix]

    local target_id_provided_directly = type(tonumber(spell.target.raw)) == 'number'
    -- If it was known that a spell was cast from menu then we could skip pretarget
    -- entirely and go straight to precast since the client has performed filter_pretarget
    -- validation for us. Unfortunately it is not possible in Windower v4 to differentiate
    -- between a menu cast, an <st> subtarget cast, or an addon providing the target ID.
    -- For this reason we cannot skip filter_pretarget's checks when a target ID is
    -- provided, but will still skip entering the pretarget event since the target
    -- has already been finalized.

    table.update(_global,global_init,true)

    if not filter_pretarget(spell) then
        return equip_sets('filtered_action',-1,spell)
    end

    if not target_id_provided_directly then
        return equip_sets('pretarget',-1,spell)
    end

    if filter_precast(spell) then
        return equip_sets('precast',-1,spell)
    end

    return storedcommand..' '..spell.target.raw
end


-----------------------------------------------------------------------------------
--Name: equip_sets(swap_type,ts,val1,val2)
--Desc: General purpose equipment pipeline / user function caller. 
--Args:
---- swap_type - Determines equip_sets' behavior in terms of which user function it
--      attempts to call
---- ts - index of command_registry or nil for pretarget/commands
---- val1 - First argument to be passed to the user function
---- val2 - Second argument to be passed to the user function
-----------------------------------------------------------------------------------
--Return (varies by swap type):
---- pretarget : empty string to blank packet or full string
---- Everything else : nil
-----------------------------------------------------------------------------------
function equip_sets(swap_type,ts,...)
    local results, proposed_packet
    local var_inps = {...}
    local val1 = var_inps[1]
    local val2 = var_inps[2]
    _global.current_event = tostring(swap_type)
    equip_sets_debug_info(swap_type,val1,val2)

    if _global.current_event == 'precast' then
        if val1.storedcommand then
            -- storedcommand being in the spell table means this spell was scheduled for later
            storedcommand = val1.storedcommand
            val1.storedcommand = nil

            -- Global vars could be in any state since we yielded, so reinitialize
            table.update(_global,global_init,true)
        end

        if val1.english and val1.english:find('Geo-') then
            -- Truthfully the target_arrow belongs in the spell table, but to minimize risk
            -- of user space having any adverse reactions to gearswap changes, we'll keep
            -- everything from user space's perspective identical.
            initialize_arrow_offset(_global.target_arrow,val1.target)

            -- Don't assemble packet yet in this case since user function
            -- may want to adjust target_arrow, so we'll wait for that so
            -- we only need to assemble the action packet once.
        else
            -- Potential behavior change: wait to see if user function decides to cancel the spell
            -- in precast before bothering to assemble the packet.
            proposed_packet = assemble_proposed_packet(val1)
            if not proposed_packet then
                return storedcommand..' '..val1.target.raw
            end
        end
    elseif _global.current_event == 'midcast' then
        command_registry[ts].midaction = true
    end

    local cur_equip = table.reassign({},update_equipment())

    table.reassign(equip_list,{})
    table.reassign(player.equipment,to_names_set(cur_equip))
    for i,v in pairs(slot_map) do
        if not player.equipment[i] then
            player.equipment[i] = player.equipment[toslotname(v)]
        end
    end

    if not val1 then val1 = {}
        if debugging.general then
            msg.debugging('val1 error')
        end
    end


    if type(swap_type) == 'function' then
        results = { pcall(swap_type,...) }
        if not table.remove(results,1) then error('\nUser Event Error: '..results[1]) end
    elseif swap_type == 'equip_command' then
        equip(val1)
    else
        user_pcall(swap_type,...)
    end

    if _global.current_event == 'precast' and val1.english and val1.english:find('Geo-') then
        proposed_packet = assemble_proposed_packet(val1)
        if not proposed_packet then
            return storedcommand..' '..val1.target.raw
        end
    end

    if player.race == 'Precomposed NPC' then
        -- Short circuits the routine and gets out before equip processing
        -- if there's no swapping to be done because the user is a monster.
        if _global.current_event == 'midcast' and command_registry[ts] and command_registry[ts].proposed_packet and not _settings.demo_mode then
            windower.packets.inject_outgoing(command_registry[ts].proposed_packet:byte(1),command_registry[ts].proposed_packet)
        end
    else
        for v,i in pairs(default_slot_map) do
            if equip_list[i] and encumbrance_table[v] then
                not_sent_out_equip[i] = equip_list[i]
                equip_list[i] = nil
                msg.debugging(i..' slot was not equipped because you are encumbered.')
            end
        end

        table.update(equip_list_history,equip_list)

        -- Attempts to identify the player-specified item in inventory
        -- Starts with (i=slot name, v=item name) 
        -- Ends with (i=slot id and v={bag_id=bag_id, slot=inventory slot}).
        local equip_next,priorities = unpack_equip_list(equip_list,cur_equip)

        if (_settings.show_swaps and table.length(equip_next) > 0) or _settings.demo_mode then --and table.length(equip_next)>0 then
            local tempset = to_names_set(equip_next)
            print_set(tempset,tostring(swap_type))
        end

        if (buffactive.charm or player.charmed) or (player.status == 2 or player.status == 3) then -- dead or engaged dead statuses
            local failure_reason
            if (buffactive.charm or player.charmed) then
                failure_reason = 'Charmed'
            elseif player.status == 2 or player.status == 3 then
                failure_reason = 'KOed'
            end
            msg.debugging("Cannot change gear right now: "..tostring(failure_reason))
            logit('\n\n'..tostring(os.clock)..'(69) failure_reason: '..tostring(failure_reason))
        else
            local chunk_table = L{}
            for eq_slot_id,priority in priorities:it() do
                if equip_next[eq_slot_id] and not encumbrance_table[eq_slot_id] and not _settings.demo_mode then
                    local minichunk = equip_piece(eq_slot_id,equip_next[eq_slot_id].bag_id,equip_next[eq_slot_id].slot)
                    chunk_table:append(minichunk)
                end
            end

            if _global.current_event == 'midcast' and command_registry[ts] and command_registry[ts].proposed_packet and not _settings.demo_mode then
                windower.packets.inject_outgoing(command_registry[ts].proposed_packet:byte(1),command_registry[ts].proposed_packet)
            end

            if chunk_table.n >= 3 then
                local big_chunk = string.char(0x51,0x24,0,0,chunk_table.n,0,0,0)
                for i=1,chunk_table.n do
                    big_chunk = big_chunk..chunk_table[i]
                end
                while string.len(big_chunk) < 0x48 do big_chunk = big_chunk..string.char(0) end
                windower.packets.inject_outgoing(0x51,big_chunk)
            elseif chunk_table.n > 0 then
                for i=1,chunk_table.n do
                    local chunk = string.char(0x50,4,0,0)..chunk_table[i]
                    windower.packets.inject_outgoing(0x50,chunk)
                end
            end
        end
    end

    if _global.cancel_spell and (_global.current_event == 'filtered_action' or _global.current_event == 'pretarget' or _global.current_event == 'precast') then
        -- Potential feature add / behavior change: if user function says to cancel the spell
        -- just cancel it immediately, rather than waiting until after we've swapped gear to cancel.
        msg.debugging('Action canceled ('..storedcommand..' '..val1.target.raw..')')
        return true
    elseif _global.current_event == 'pretarget' then
        if _global.new_target then
            val1.target = _global.new_target
        end

        if st_targs[val1.target.raw] then
            st_flag = true
            return storedcommand..' '..val1.target.raw
        elseif filter_precast(val1) then
            if _global.pretarget_cast_delay == 0 then
                return equip_sets('precast',ts,val1)
            else
                val1.storedcommand = storedcommand
                equip_sets:schedule(_global.pretarget_cast_delay,'precast',ts,val1)
                return true
            end
        else
            -- Did not have a valid target to be able to enter precast
            return storedcommand..' '..val1.target.raw
        end
    elseif _global.current_event == 'precast' then
        -- Only invoke the command registry when we will for sure fire
        ts = command_registry:new_entry(val1)
        command_registry[ts].proposed_packet = proposed_packet

        if _global.precast_cast_delay == 0 then
            equip_sets('midcast',ts,val1)
        else
            command_registry[ts].precast_cast_delay = _global.precast_cast_delay
            equip_sets:schedule(_global.precast_cast_delay,'midcast',ts,val1)
        end
        return true
    elseif _global.current_event == 'midcast' and _settings.demo_mode then
        command_registry[ts].midaction = false
        equip_sets('aftercast',ts,val1)
    elseif _global.current_event == 'aftercast' or _global.current_event == 'pet_aftercast' then
        if ts then
            command_registry:delete_entry(ts)
        end
    end

    windower.debug(tostring(swap_type)..' exit')

    if type(swap_type) == 'function' then
        return unpack(results)
    end
end


-----------------------------------------------------------------------------------
--Name: user_pcall(str,...)
--Desc: Calls a user function, if it exists. If not, throws an error.
--Args:
---- str - Function's key in user_env.
-----------------------------------------------------------------------------------
--Returns:
---- none
-----------------------------------------------------------------------------------
function user_pcall(str,...)
    if user_env then
        if type(user_env[str]) == 'function' then
            bool,err = pcall(user_env[str],...)
            if not bool then error('\nGearSwap has detected an error in the user function '..str..':\n'..err) end
        elseif user_env[str] then
            msg.addon_msg(123,windower.to_shift_jis(tostring(str))..'() exists but is not a function')
        end
    end
end


-----------------------------------------------------------------------------------
--Name: user_pcall2(str,...)
--Desc: Calls a user function, if it exists. If not, prints an error and continues.
--Args:
---- str - Function's key in user_env.
-----------------------------------------------------------------------------------
--Returns:
---- none
-----------------------------------------------------------------------------------
function user_pcall2(str,...)
    if user_env then
        if type(user_env[str]) == 'function' then
            bool,err = pcall(user_env[str],...)
            if not bool then print('\nGearSwap has detected an error in the user function '..str..':\n'..err) end
        elseif user_env[str] then
            msg.addon_msg(123,windower.to_shift_jis(tostring(str))..'() exists but is not a function')
        end
    end
end


-----------------------------------------------------------------------------------
--Name: assemble_proposed_packet(spell)
--Desc: Puts together the correct packet for the requested spell.
--Args:
---- spell - Spell table for the requested spell
-----------------------------------------------------------------------------------
--Returns:
---- none
-----------------------------------------------------------------------------------
function assemble_proposed_packet(spell)
    local proposed_packet
    if spell.action_type == 'Trade' then
        -- 0x36 packet
        proposed_packet = assemble_menu_item_packet(spell.target.id,spell.target.index,spell.id)
    elseif spell.action_type == 'Item' then
        -- 0x37 packet
        proposed_packet = assemble_use_item_packet(spell.target.id,spell.target.index,spell.id)
    elseif outgoing_action_category_table[unify_prefix[spell.prefix]] then
        -- 0x1A packet
        proposed_packet = assemble_action_packet(spell.target.id,spell.target.index,outgoing_action_category_table[unify_prefix[spell.prefix]],spell.id,_global.target_arrow)
    else
        msg.debugging("Hark, what weird prefix through yonder window breaks? "..tostring(spell.prefix))
    end
    return proposed_packet
end


-----------------------------------------------------------------------------------
--Name: equip_sets_debug_info(swap_type,val1,val2)
--Desc: Consolidates a bunch of debug prints to reduce noise in the main code path.
--Args:
---- swap_type - Determines equip_sets' behavior in terms of which user function it
--      attempts to call
---- val1 - First argument to be passed to the user function
---- val2 - Second argument to be passed to the user function
-----------------------------------------------------------------------------------
--Returns:
---- none
-----------------------------------------------------------------------------------
function equip_sets_debug_info(swap_type,val1,val2)
    windower.debug(tostring(swap_type)..' enter')
    if showphase or debugging.general then msg.debugging(windower.to_shift_jis(tostring(swap_type))..' enter') end

    logit('\n\n'..tostring(os.clock)..'(15) equip_sets: '..tostring(swap_type))
    if val1 then
        if type(val1) == 'table' and val1.english then
            logit(' : '..val1.english)
        else
            logit(' : Unknown type val1- '..tostring(val1))
        end
    else
        logit(' : nil-or-false')
    end
    if val2 then
        if type(val2) == 'table' and val2.type then logit(' : '..val2.type)
        else
            logit(' : Unknown type val2- '..tostring(val2))
        end
    else
        logit(' : nil-or-false')
    end

    if type(swap_type) == 'string' then
        msg.debugging("Entering "..swap_type)
    else
        msg.debugging("Entering User Event "..tostring(swap_type))
    end
end
