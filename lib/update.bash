# UPDATE projections retain old columns and show the values in equality quals
# and SET assignments. SET wins if a column occurs in both places.
update_add_column() {
    local name=$1 value=$2 assigned=$3 canonical i
    canonical_ident "$name"; canonical=$CANONICAL
    for ((i=0; i<${#update_columns[@]}; i++)); do
        if [[ ${update_canonical[i]} == "$canonical" ]]; then
            if [[ $assigned == yes ]]; then update_values[i]=$value; fi
            return 0
        fi
    done
    update_columns+=("$name"); update_canonical+=("$canonical")
    update_values+=("$value")
}

# Parse Boolean groups without changing their grouping. Qualifier projection
# inference deliberately requires a column on the left of each predicate.
update_quals() {
    local lo=$1 hi=$2 i begin=$1 between=0 cases=0 split=0
    while [[ ${T[lo]:-} == '(' ]] && ((M[lo]==hi-1)); do ((lo+=1, hi-=1)); done
    ((lo<hi)) || { fail 'empty WHERE condition'; return 1; }
    begin=$lo
    for ((i=lo; i<hi; i++)); do
        if [[ ${T[i]} == '(' || ${T[i]} == '[' ]]; then i=${M[i]}; continue; fi
        if is_word "$i" CASE; then ((cases+=1)); continue; fi
        if is_word "$i" END && ((cases)); then ((cases-=1)); continue; fi
        ((cases==0)) || continue
        if is_word "$i" BETWEEN; then between=1; continue; fi
        if is_word "$i" AND && ((between)); then between=0; continue; fi
        if is_word "$i" AND || is_word "$i" OR; then
            is_word "$i" OR && simple_quals=0
            update_quals "$begin" "$i" || return
            begin=$((i+1)); split=1
        fi
    done
    if ((split)); then update_quals "$begin" "$hi"; return; fi
    if is_word "$lo" NOT; then
        simple_quals=0; update_quals "$((lo+1))" "$hi"; return
    fi
    local pos=$lo ident name qualifier='' col_start=$lo rhs end value=''
    identifier || { fail 'WHERE projection needs column-led predicates'; return 1; }
    name=$ident
    while [[ ${T[pos]:-} == '.' ]]; do
        qualifier+="$name."
        ((pos+=1)); identifier || return; name=$ident
    done
    ((pos<hi)) || { fail 'WHERE predicate is missing an operator'; return 1; }
    if [[ ${T[pos]} == '(' || ${T[pos]} == '[' ]]; then
        fail 'function/array expressions on the left of WHERE predicates are not supported'; return 1
    fi
    if [[ -n $qualifier && $qualifier != "$target_ref." && $qualifier != "$table." ]]; then
        fail 'WHERE projection currently requires target-table columns'; return 1
    fi
    if [[ ${T[pos]} == '=' && ${T[pos+1]:-} != '>' ]]; then
        rhs=$((pos+1)); ((rhs<hi)) || { fail 'missing equality value'; return 1; }
        end=${E[hi-1]}; value=${sql:S[rhs]:end-S[rhs]}
        qual_columns+=("$name"); qual_values+=("$value")
    else
        simple_quals=0
    fi
    # Distinct equality values for the same column cannot share one new_ label.
    local canonical j
    canonical_ident "$name"; canonical=$CANONICAL
    for ((j=0; j<${#update_columns[@]}; j++)); do
        if [[ $operation == UPDATE && ${update_canonical[j]} == "$canonical" && -n $value &&
              -n ${update_values[j]} && ${update_values[j]} != "$value" ]]; then
            fail "multiple WHERE values for $name cannot share one new_ column"; return 1
        fi
    done
    update_add_column "$name" "$value" yes
}

convert_row_preview() {
    local sql=$1 pos=0 ident table target_ref target_sql prefix='' only='' star='' alias=''
    local operation=$2 source_keyword=FROM
    [[ $operation == DELETE ]] && source_keyword=USING
    local i j count set_start set_end from_pos=-1 where_pos=-1 returning_pos=-1 end begin close
    local simple_quals=1
    local -a T S E D M K update_columns=() update_values=() update_canonical=()
    local -a qual_columns=() qual_values=() set_columns=() set_values=()
    tokenize "$sql" || return
    count=${#T[@]}
    if is_word 0 WITH; then
        while ((pos<count)); do
            if ((D[pos]==0)) && is_word "$pos" "$operation"; then break; fi
            if is_word "$pos" INSERT || is_word "$pos" UPDATE || is_word "$pos" DELETE || is_word "$pos" MERGE; then
                fail 'data-modifying WITH queries are not supported'; return 1
            fi
            ((pos+=1))
        done
        ((pos<count)) || { fail "expected $operation after WITH"; return 1; }
        prefix=${sql:0:S[pos]}
    fi
    is_word "$pos" "$operation" || { fail "input must contain only $operation statements"; return 1; }
    ((pos+=1))
    if [[ $operation == DELETE ]]; then
        is_word "$pos" FROM || { fail 'expected FROM after DELETE'; return 1; }
        ((pos+=1))
    fi
    if is_word "$pos" ONLY; then only='ONLY '; ((pos+=1)); fi
    identifier || return; table=$ident; target_ref=$ident
    while [[ ${T[pos]:-} == '.' ]]; do
        ((pos+=1)); identifier || return; table+=".$ident"; target_ref=$ident
    done
    if [[ ${T[pos]:-} == '*' ]]; then star=' *'; ((pos+=1)); fi
    if is_word "$pos" AS; then
        ((pos+=1)); identifier || return; alias=$ident
    elif ((pos<count)) && ! is_word "$pos" SET && ! is_word "$pos" USING &&
         ! is_word "$pos" WHERE && ! is_word "$pos" RETURNING; then
        identifier || return; alias=$ident
    fi
    target_sql="$only$table$star"
    if [[ -n $alias ]]; then target_sql+=" AS $alias"; target_ref=$alias; fi
    if [[ $operation == UPDATE ]]; then
        is_word "$pos" SET || { fail 'expected SET'; return 1; }
        ((pos+=1))
    elif ((pos<count)) && ! is_word "$pos" USING && ! is_word "$pos" WHERE && ! is_word "$pos" RETURNING; then
        fail 'expected USING, WHERE, RETURNING, or end of DELETE'; return 1
    fi
    set_start=$pos; set_end=$count
    for ((i=set_start; i<count; i++)); do
        ((D[i]==0)) || continue
        if is_word "$i" "$source_keyword" && ((from_pos<0)); then from_pos=$i
        elif is_word "$i" WHERE && ((where_pos<0)); then where_pos=$i
        elif is_word "$i" RETURNING; then returning_pos=$i; break
        else continue; fi
        ((set_end==count)) && set_end=$i
    done
    if ((returning_pos>=0 && set_end==count)); then set_end=$returning_pos; fi
    if [[ $operation == UPDATE ]]; then
        pos=$set_start
        while ((pos<set_end)); do
            local -a names=() values=()
            if [[ ${T[pos]} == '(' ]]; then
                close=${M[pos]}; ((pos+=1))
                while ((pos<close)); do
                    identifier || return; names+=("$ident")
                    if ((pos<close)); then
                        [[ ${T[pos]} == ',' ]] || { fail 'invalid tuple target'; return 1; }
                        ((pos+=1))
                    fi
                done
                ((pos+=1))
            else
                identifier || return; names+=("$ident")
            fi
            [[ ${T[pos]:-} == '=' ]] || { fail 'expected = after SET column (field/array targets are unsupported)'; return 1; }
            ((pos+=1)); begin=$pos
            while ((pos<set_end)); do
                [[ ${T[pos]} == ',' && ${D[pos]} == 0 ]] && break
                ((pos+=1))
            done
            ((pos>begin)) || { fail 'empty SET expression'; return 1; }
            end=${E[pos-1]}
            if ((${#names[@]}==1)); then
                values+=("${sql:S[begin]:end-S[begin]}")
            else
                is_word "$begin" ROW && ((begin+=1))
                [[ ${T[begin]} == '(' ]] && ((M[begin]==pos-1)) || { fail 'expected a tuple SET value'; return 1; }
                if is_word "$((begin+1))" SELECT || is_word "$((begin+1))" WITH; then
                    fail 'multi-column subquery assignments are not supported'; return 1
                fi
                local depth=$((D[begin]+1)) part=$((begin+1))
                for ((i=part; i<pos; i++)); do
                    if ((i==pos-1)) || { [[ ${T[i]} == ',' ]] && ((D[i]==depth)); }; then
                        ((i>part)) || { fail 'empty tuple value'; return 1; }
                        end=${E[i-1]}; values+=("${sql:S[part]:end-S[part]}"); part=$((i+1))
                    fi
                done
            fi
            ((${#names[@]}==${#values[@]})) || { fail 'tuple column/value counts differ'; return 1; }
            set_columns+=("${names[@]}"); set_values+=("${values[@]}")
            if ((pos<set_end)); then
                ((pos+=1)); ((pos<set_end)) || { fail 'trailing SET comma'; return 1; }
            fi
        done
        ((${#set_columns[@]})) || { fail 'empty SET list'; return 1; }
    fi
    local where_sql='' from_sql=''
    end=$count; ((returning_pos>=0)) && end=$returning_pos
    if ((where_pos>=0)); then
        if is_word "$((where_pos+1))" CURRENT; then
            fail 'WHERE CURRENT OF requires cursor state and cannot be converted'; return 1
        fi
        update_quals "$((where_pos+1))" "$end" || return
        begin=${S[where_pos+1]}; j=${E[end-1]}; where_sql=${sql:begin:j-begin}
        # Rewrite only standalone equality operators in WHERE, never SET values.
        if [[ $comparison_operator != '=' ]]; then
            for ((i=end-1; i>where_pos; i--)); do
                [[ ${T[i]} == '=' ]] || continue
                if ((i>0 && E[i-1]==S[i])) && [[ ${T[i-1]} == [\<\>\!\=\~] ]]; then continue; fi
                if ((i+1<end && E[i]==S[i+1])) && [[ ${T[i+1]} == [\>\=] ]]; then continue; fi
                j=$((S[i]-begin))
                where_sql="${where_sql:0:j} IS NOT DISTINCT FROM ${where_sql:j+1}"
            done
        fi
    fi
    if ((${#key_specs[@]})) || [[ $match_mode == any ]]; then
        ((simple_quals && ${#qual_columns[@]}>0)) || {
            fail '--key/--match any require a WHERE clause of ANDed column equalities'; return 1;
        }
        local -a columns=("${qual_columns[@]}") expressions=("${qual_values[@]}") GROUPS_SELECTED=()
        local predicate_kind=values
        select_keys || return; make_predicate || return; where_sql=$PREDICATE
    fi
    for ((i=0; i<${#set_columns[@]}; i++)); do
        [[ ${set_values[i]^^} != DEFAULT ]] || { fail 'DEFAULT requires a table definition'; return 1; }
        update_add_column "${set_columns[i]}" "${set_values[i]}" yes
    done
    local -a order=()
    if [[ -n $implicit_columns ]]; then
        parse_ident_list "$implicit_columns" || return
        for ident in "${PARSED_COLUMNS[@]}"; do
            canonical_ident "$ident"; local found=0
            for ((i=0; i<${#update_columns[@]}; i++)); do
                if [[ $CANONICAL == "${update_canonical[i]}" ]]; then order+=("$i"); found=1; break; fi
            done
            if ((!found)); then
                if [[ $operation == DELETE ]]; then
                    update_add_column "$ident" '' no
                    order+=("$((${#update_columns[@]}-1))")
                else
                    fail "projection column $ident is absent from WHERE and SET"; return 1
                fi
            fi
        done
    elif [[ $operation == UPDATE || ${select_quals:-0} == 1 ]]; then
        for ((i=0; i<${#update_columns[@]}; i++)); do order+=("$i"); done
    fi
    if ((from_pos>=0)); then
        end=$count; ((returning_pos>=0)) && end=$returning_pos; ((where_pos>=0)) && end=$where_pos
        ((from_pos+1<end)) || { fail "empty $source_keyword clause"; return 1; }
        begin=${S[from_pos+1]}; j=${E[end-1]}; from_sql=${sql:begin:j-begin}
    fi
    local projection='' name value new_name
    for i in "${order[@]}"; do
        [[ -z $projection ]] || projection+=', '
        name=${update_columns[i]}
        if [[ -n $alias || -n $from_sql ]]; then name="$target_ref.$name"; fi
        projection+=$name
    done
    if [[ $operation == UPDATE ]]; then
        for i in "${order[@]}"; do
            value=${update_values[i]}; [[ -n $value ]] || continue
            canonical_ident "${update_columns[i]}"; new_name="new_$CANONICAL"
            if [[ $new_name =~ ^[a-z_][a-z0-9_]*$ ]]; then :
            else new_name=\"${new_name//\"/\"\"}\"; fi
            projection+=", $value AS $new_name"
        done
    fi
    if [[ -z $projection ]]; then
        projection='*'
        if [[ -n $alias || -n $from_sql ]]; then projection="$target_ref.*"; fi
    fi
    RESULT="${prefix}SELECT $projection FROM $target_sql"
    [[ -z $from_sql ]] || RESULT+=", $from_sql"
    [[ -z $where_sql ]] || RESULT+=" WHERE $where_sql"
    RESULT+=';'
}

convert_update() {
    convert_row_preview "$1" UPDATE
}
