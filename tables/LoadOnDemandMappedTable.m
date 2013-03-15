classdef LoadOnDemandMappedTable < StructTable
% This table type is useful for referencing data that is linked via a one-to-one
% relationship with another table, but is very large and should only be loaded
% when necessary and typically one or a few entries at a time
%
% This table type is abstract, and classes which override it must define the 
% specific fields which will be loaded, and a function which returns the
% loaded values of these fields for a specific entry, i.e. loads the values.

    properties(SetAccess=protected)
        loadedByEntry % loadedByEntry(iEntry).field = true/false
        cacheTimestampsByEntry % cacheTimestampsByEntry(iEntry).field = timestamp for which
                               % cache was loaded
    end

    properties
        % ignore cached field values earlier than this date
        fieldValueCacheValidAfterTimestamp = -Inf;

        % fields in this table may be returned by getFieldsCacheable meaning that their values
        % are stored in individual cache entries. When cacheing the entire table as a whole, 
        % it makes sense to unload these values automatically before saving the table down
        % so that the file size doesn't include the values of these fields which are duplicated
        % elsewhere
        unloadCacheableFieldsOnCacheTable = true;
    end

    properties(Dependent)
        fieldsLoadOnDemand
        fieldsLoadOnDemandDescriptorMap
        fieldsCacheable % subset of fieldsLoadOnDemand
        fieldsCacheableDescriptorMap
    end
    
    properties(Transient, Access=protected)
        cachedFieldsLoadOnDemand
        cachedFieldsLoadOnDemandDescriptorMap
        cachedFieldsNotLoadOnDemand
        cachedFieldsNotLoadOnDemandDescriptorMap
        cachedFieldsCacheable
        cachedFieldsCacheableDescriptorMap
    end

    methods(Abstract)
        % Return entry name for this table
        [entryName entryNamePlural] = getEntryName(dt)

        % LoadOnDemandMappedTables are defined via a one-to-one relationship with
        % another data table. Here you define the entryName of that corresponding
        % DataTable. When you call the constructor on this table, you must pass
        % in a Database which must have this table in it.
        entryName = getMapsEntryName(dt) 

        % return a list of fields which are empty when creating this table
        % but can be loaded by a call to loadFields. These fields typically 
        % contain large amounts of data and are typically loaded only when needed
        % rather than cached as part of the table and thereby loaded in aggregate.
        [fields fieldDescriptorMap] = getFieldsLoadOnDemand(dt)

        % from the fields above, return a list of fields that you would like
        % to be cached automatically, using independent mat files for each entry
        % For these fields, the cache will be loaded if present, otherwise
        % loadValuesForEntry will be called. 
        fields = getFieldsCacheable(dt)

        % these are fields not in load on demand, they will be cached with the 
        % table. the keyFields of the mapped table will be automatically included
        % as part of this set, you need not return them
        [fields fieldDescriptorMap] = getFieldsNotLoadOnDemand(dt)
        
        % here's where you specify where the values for the loaded fields come
        % from. When passed a list of fields, guaranteed to be valid, you generate
        % or load the values of those fields for a specific entry in the mapped table
        % and return a struct containing those field values.
        valueStruct = loadValuesForEntry(dt, entry, fields)
    end
    
    methods % methods a subclass might wish to override
        % indicate the CacheManager you would like to use to cache and load
        % the values of cacheable fields (i.e. as returned by getFieldsCacheable())
        function cm = getFieldValueCacheManager(dt)
            cm = CacheManager();
        end
        
        % oldest cache timestamp that will be treated as valid as a ValueMap from
        % field name to timestamp.
        function cacheValidTimestamp = getCacheValidTimestampForField(dt, field)
            cacheValidTimestamp = dt.fieldValueCacheValidAfterTimestamp; 
        end

        % return the param to pass to the cache manager when searching for the 
        % cached value of this field. the cache name already includes the name
        % of the field, so this is not necessary to include. The default method
        % below includes whatever cache params are specified by the table, though
        % if you override this and wish to preserve this functionality, you will
        % need to include this as well. You do not need to worry about including
        % information about the keyfields of the current entry, this will be 
        % taken care of automatically
        function cacheParam = getCacheParamForField(dt, field)
            cacheParam = dt.getCacheParam();
        end
    end

    methods
        function dt = LoadOnDemandMappedTable(varargin)
            dt = dt@StructTable();

            if ~isempty(varargin)
                dt = dt.initialize(varargin{:});
            end
        end

        function dt = initialize(dt, varargin)
            % Build the table by generating a row via the one-to-one mapping 
            % to the database table. All entries will initially be empty for fields
            % that are loaded on demand.
            
            p = inputParser;
            p.KeepUnmatched = true;
            
            % specify either a database (which we can use to find the table this table
            % maps to in order to build the one to one relationship)
            p.addParamValue('database', '', @(db) isa(db, 'Database'));
            % or specify a table directly
            p.addParamValue('table', '', @(db) isa(db, 'DataTable'));
            % if specifying table directly, rely on user to specify which fields are loaded
            p.addParamValue('fieldsLoaded', {}, @iscellstr);
            p.addParamValue('entryName', '', @ischar);
            p.addParamValue('entryNamePlural', '', @ischar);
            p.parse(varargin{:});
            
            db = p.Results.database;
            table = p.Results.table;
            fieldsLoaded = p.Results.fieldsLoaded;
            entryName = p.Results.entryName;
            entryNamePlural = p.Results.entryNamePlural;
            if isempty(db) && isempty(table)
                error('Please provide "database" param in order to lookup mapped table or "table" param directly');
            end

            if isempty(entryName)
                [entryName entryNamePlural] = dt.getEntryName();
            else
                if isempty(entryNamePlural)
                    entryNamePlural = [entryName 's'];
                end
            end

            if isempty(table)
                % no table specified, build it via mapping one-to-one off database table
                entryNameMap = dt.getMapsEntryName(); 
                debug('Mapping LoadOnDemand table off table %s\n', entryNameMap);
                table = db.getTable(entryNameMap).keyFieldsTable;
                
                table = table.setEntryName(entryName, entryNamePlural);
                
                % add additional fields
                [fields dfdMap] = dt.getFieldsNotLoadOnDemand();
                dt.cachedFieldsNotLoadOnDemand = fields;
                dt.cachedFieldsNotLoadOnDemandDescriptorMap = dfdMap;
                for iField = 1:length(fields)
                    field = fields{iField};
                    table = table.addField(field, [], 'fieldDescriptor', dfdMap(field));
                    table = table.applyFields();
                end

                % add load on demand fields
                [fields dfdMap] = dt.getFieldsLoadOnDemand();
                dt.cachedFieldsLoadOnDemand = fields;
                dt.cachedFieldsLoadOnDemandDescriptorMap = dfdMap;
                for iField = 1:length(fields)
                    field = fields{iField};
                    table = table.addField(field, [], 'fieldDescriptor', dfdMap(field));
                    table = table.applyFields();
                end

                fieldsLoaded = {};
            else
                db = table.database;
                assert(~isempty(db), 'Table must be linked to a database');
            end
            
            dt.cachedFieldsCacheable = dt.getFieldsCacheable();

            % initialize in StructTable 
            dt = initialize@StructTable(dt, table, p.Unmatched); 

            dt.loadedByEntry = dt.generateLoadedByEntry('fieldsLoaded', fieldsLoaded);
            dt.cacheTimestampsByEntry = dt.generateCacheTimestampsByEntry();

            dt = db.addTable(dt);
            db.addRelationshipOneToOne(entryNameMap, entryName);
        end
    end

    methods(Access=protected) % StructTable overrides
        % need to extend this in order to filter loadedByEntry appropriately
        function dt = selectSortEntries(dt, indsInSortOrder)
            dt = selectSortEntries@StructTable(dt, indsInSortOrder);
            if ~isempty(dt.loadedByEntry) && isstruct(dt.loadedByEntry)
                dt.loadedByEntry = dt.loadedByEntry(indsInSortOrder, 1);
            end
            if ~isempty(dt.cacheTimestampsByEntry) && isstruct(dt.cacheTimestampsByEntry)
                dt.cacheTimestampsByEntry = dt.cacheTimestampsByEntry(indsInSortOrder, 1);
            end
        end

        % need to extend this in order to add new rows to loadedByEntry appropriately
        function dt = subclassAddEntry(dt, S)
            % we can only assume that any entries which are added are not loaded
            newLoadedByEntry = emptyStructArray([length(S) 1], dt.fieldsLoadOnDemand, 'val', false);
            dt.loadedByEntry = [dt.loadedByEntry; newLoadedByEntry];

            % and assume not loaded from cache
            newCacheTimestampsByEntry = emptyStructArray([length(S) 1], dt.fieldsCacheable);
            dt.cacheTimestampsByEntry = [dt.cacheTimestampsByEntry; newCacheTimestampsByEntry];
            dt = subclassAddEntry@StructTable(dt, S); 
        end
    end

    methods % Dependent properties
        function fields = get.fieldsLoadOnDemand(dt)
            fields = dt.cachedFieldsLoadOnDemand;
        end
        
        function map = get.fieldsLoadOnDemandDescriptorMap(dt)
            map = dt.cachedFieldsLoadOnDemandDescriptorMap;
        end

        function fields = get.fieldsCacheable(dt)
            fields = dt.cachedFieldsCacheable;
        end
    end

    methods % Loading and unloading fields
        function loadedByEntry = generateLoadedByEntry(dt, varargin)
            % build an initial value for the loadedByEntry struct array
            % for which loadedByEntry(iEntry).field is .NotLoaded for all fields
            % unless field is a member of param fieldsLoaded 
            p = inputParser;
            p.addParamValue('fieldsLoaded', {}, @iscellstr);
            p.parse(varargin{:});
            fieldsLoaded = p.Results.fieldsLoaded;
            dt.assertIsField(fieldsLoaded);

            fieldsNotLoaded = setdiff(dt.fieldsLoadOnDemand, fieldsLoaded);
            loadedByEntry = emptyStructArray([dt.nEntries 1], dt.fieldsLoadOnDemand);
            loadedByEntry = assignIntoStructArray(loadedByEntry, fieldsNotLoaded, false);
            loadedByEntry = assignIntoStructArray(loadedByEntry, fieldsLoaded, true); 
        end

        function cacheTimestampsByEntry = generateCacheTimestampsByEntry(dt)
            % build an initial value for the loadedByEntry struct array
            % for which loadedByEntry(iEntry).field is .NotLoaded for all fields
            % unless field is a member of param fieldsLoaded 
            
            cacheTimestampsByEntry = emptyStructArray([dt.nEntries 1], dt.fieldsCacheable);
        end

        function dt = loadField(dt, field, varargin)
            dt.warnIfNoArgOut(nargout);
            dt = dt.loadFields('fields', field, varargin{:});
        end

        % load in the loadable values for fields listed in fields (1st optional
        % argument)
        function [dt valuesByEntry] = loadFields(dt, varargin)
            dt.warnIfNoArgOut(nargout);
            
            p = inputParser;

            % specify a subset of fieldsLoadOnDemand to load
            p.addParamValue('fields', dt.fieldsLoadOnDemand, @(x) ischar(x) || iscellstr(x));

            % if true, force reload of ALL fields
            p.addParamValue('reload', false, @islogical);

            % if false, ignore cached values for fieldsCacheable
            p.addParamValue('loadCache', true, @islogical);

            % if true, only load values from a saved cache, don't call load method
            p.addParamValue('loadCacheOnly', false, @islogical);

            % if true, don't load cache values, just populate cacheTimestamps with timestamps 
            p.addParamValue('loadCacheTimestampsOnly', false, @islogical);
            
            % only load for selected entries
            p.addParamValue('entryMask', true(dt.nEntries, 1), @(x) true);

            % if false, don't save newly loaded values in the cache
            p.addParamValue('saveCache', true, @islogical);

            % if false, don't actually hold onto the value in the table
            % just return the values
            p.addParamValue('storeInTable', true, @islogical);
            p.parse(varargin{:});
            
            fields = p.Results.fields;
            if ischar(fields)
                fields = {fields};
            end
            reload = p.Results.reload;
            loadCache = p.Results.loadCache;
            loadCacheOnly = p.Results.loadCacheOnly;
            loadCacheTimestampsOnly = p.Results.loadCacheTimestampsOnly;
            saveCache = p.Results.saveCache;
            storeInTable = p.Results.storeInTable;
            entryMask = p.Results.entryMask;

            if loadCacheTimestampsOnly
                % this flag overwrites other options so that we only grab the timestamps
                reload = false;
                loadCache = false;
                loadCacheOnly = true;
                saveCache = false;
                storeInTable = false;
            end

            % check fields okay
            validField = ismember(fields, dt.fieldsLoadOnDemand);
            assert(all(validField), 'Fields %s not found in fieldsLoadOnDemand', ...
                strjoin(fields(~validField)));

            % figure out which fields to check in cache
            fieldsCacheable = intersect(dt.fieldsCacheable, fields);

            valuesByEntry = []; 

            savedAutoApply = dt.autoApply;
            dt = dt.apply();
            dt = dt.setAutoApply(false);

            entryDescriptions = dt.getKeyFieldValueDescriptors();

            % loop through entries, load fields and overwrite table values
            loadedCount = 0;
            for iEntry = 1:dt.nEntries
                if ~entryMask(iEntry)
                    continue;
                end
                
                progressStr = sprintf('[%5.1f %%]', 100 * loadedCount / nnz(entryMask));
                loadedCount = loadedCount + 1;

                % loaded.field is true if field is loaded already for this entry
                loaded = dt.loadedByEntry(iEntry);
                cacheTimestamps = dt.cacheTimestampsByEntry(iEntry);
                % to store loaded values for this entry
                loadedValues = struct();

                if reload 
                    % force reload of all fields
                    loaded = assignIntoStructArray(loaded, fieldnames(loaded), false);
                end

                % first, look up cacheable fields in cache
                if loadCache
                    hasPrintedMessage = false;

                    for iField = 1:length(fieldsCacheable)
                        field = fieldsCacheable{iField};
                        if loaded.(field)
                            % already loaded
                            continue;
                        end
                        if ~hasPrintedMessage 
                            % load cache values and timestamps, store in table later
                            fprintf('%s Retrieving cached fields for %s                \r', ...
                                progressStr, entryDescriptions{iEntry});
                            hasPrintedMessage = true;
                        end
                        
                        [validCache value timestamp] = dt.retrieveCachedFieldValue(iEntry, field);
                        if validCache
                            % found cached value
                            loadedValues.(field) = value;
                            loaded.(field) = true;
                            cacheTimestamps.(field) = timestamp;
                        end
                    end

                elseif loadCacheTimestampsOnly
                    hasPrintedMessage = false;
                    

                    for iField = 1:length(fieldsCacheable)
                        field = fieldsCacheable{iField};
                        if loaded.(field)
                            % already loaded, don't bother with timestamp
                            continue;
                        end
                        if ~hasPrintedMessage
                            % only load timestamps into cacheTimestamps, not the actual values
                            fprintf('%s Retrieving cache timestamps for %s              \r', ...
                                progressStr, entryDescriptions{iEntry});
                            hasPrintedMessage = true;
                        end
                        [validCache timestamp] = dt.retrieveCachedFieldTimestamp(iEntry, field);
                        cacheTimestamps.(field) = timestamp;
                    end
                end

                % manually request the values of any remaining fields
                if ~loadCacheOnly
                    loadedMask = cellfun(@(field) loaded.(field), fields);
                    fieldsToRetrieve = fields(~loadedMask);

                    if ~isempty(fieldsToRetrieve)
                        fprintf('%s Requesting value for entry %d fields %s            \r', ...
                            progressStr, iEntry, strjoin(fieldsToRetrieve, ', '));
                        thisEntry = dt.select(iEntry).apply();
                        mapEntryName = dt.getMapsEntryName();
                        mapEntry = thisEntry.getRelated(mapEntryName);
                        S = dt.loadValuesForEntry(mapEntry, fieldsToRetrieve);
                    
                        retFields = fieldnames(S);
                        for iField = 1:length(retFields)
                            field = retFields{iField};
                            loadedValues.(field) = S.(field);
                            loaded.(field) = true;
                            if saveCache && ismember(field, fieldsCacheable)
                                % cache the newly loaded value
                                dt.cacheFieldValue(iEntry, field, 'value', loadedValues.(field));
                            end
                        end
                    end
                end

                % store the values in the table's fields
                loadedFields = fieldnames(loadedValues);

                if storeInTable
                    for iField = 1:length(loadedFields)
                        field = loadedFields{iField};
                        % no need to save cache here, already handled above
                        dt = dt.setFieldValue(iEntry, field, loadedValues.(field), ...
                            'saveCache', false);
                    end
                    dt.loadedByEntry(iEntry) = loaded;
                end
                
                dt.cacheTimestampsByEntry(iEntry) = cacheTimestamps;

                if ~loadCacheTimestampsOnly
                    % build table of loaded values
                    for iField = 1:length(fields)
                        field = fields{iField};
                        if isfield(loadedValues, field)
                            valuesByEntry(iEntry).(field) = loadedValues.(field);
                        else
                            valuesByEntry(iEntry).(field) = [];
                        end
                    end
                else
                    valuesByEntry = [];
                end
            end

            fprintf('\n');

            dt = dt.apply();
            dt = dt.setAutoApply(savedAutoApply);
        end

        function value = retrieveValue(dt, field, varargin)
            assert(dt.nEntries == 1, 'retrieveValue only valid for single entries');
            [dt values] = dt.loadFields('fields', {field}, 'storeInTable', false, varargin{:});
            value = values.(field);
        end

        function dt = unloadFields(dt, varargin)
            dt.warnIfNoArgOut(nargout);
            
            p = inputParser;
            p.addOptional('fields', dt.fieldsLoadOnDemand, @iscellstr);
            p.parse(varargin{:});
            fields = p.Results.fields;

            % check fields okay
            validField = ismember(fields, dt.fieldsLoadOnDemand);
            assert(all(validField), 'Fields %s not found in fieldsLoadOnDemand', ...
                strjoin(fields(~validField)));

            % loop through entries, set fields to [] 
            % empty value will be converted to correct value via field descriptor
            for iEntry = 1:dt.nEntries
                for iField = 1:length(fields)
                    field = fields{iField}; 
                    % it's crucial here that when setting this value it is not cached
                    dt = dt.setFieldValue(iEntry, field, [], 'saveCache', false, ...
                        'markUnloaded', true);
                    dt.loadedByEntry(iEntry).(field) = false;
                end
            end
        end

        % augment the set field value method with one that automatically caches
        % the new value to disk
        function dt = setFieldValue(dt, idx, field, value, varargin)
            p = inputParser;
            % write-down this value to the cache for this field value
            p.addParamValue('saveCache', true, @islogical);
            % if false, doesn't store the result in table, useful in conjuction
            % with saveCache
            p.addParamValue('storeInTable', true, @islogical);
            % mark the entry loaded in .loadedByEntry
            p.addParamValue('markLoaded', true, @islogical);
            % mark the entry unloaded in .loadedByEntry
            p.addParamValue('markUnloaded', false, @islogical);
            p.parse(varargin{:});
            saveCache = p.Results.saveCache;
            storeInTable = p.Results.storeInTable;
            markLoaded = p.Results.markLoaded;
            markUnloaded = p.Results.markUnloaded;

            dt.warnIfNoArgOut(nargout);
            if storeInTable
                dt = setFieldValue@StructTable(dt, idx, field, value);
            end
            if storeInTable && markLoaded && ismember(field, dt.fieldsLoadOnDemand)
                dt.loadedByEntry(idx).(field) = true;
            end
            if storeInTable && markUnloaded && ismember(field, dt.fieldsLoadOnDemand)
                dt.loadedByEntry(idx).(field) = false;
            end
            if saveCache && ismember(field, dt.fieldsCacheable)
                dt.cacheFieldValue(idx, field, 'value', value);
                dt.cacheTimestampsByEntry(idx).field = now;
            end
        end
    end
        
    methods % Caching field values
        % generate the cache name used to store 
        function name = getCacheNameForFieldValue(dt, field)
            name = sprintf('%s_%s', dt.getCacheName(), field);
        end

        % build the cache param to be used for field field on entry idx
        % this includes the manually specified params as well as the keyFields
        % of entry idx
        function param = getCacheParamForFieldValue(dt, idx, field)
            %vals = dt.select(idx).apply().getFullEntriesAsStruct();
            %param.keyFields = rmfield(vals, setdiff(fieldnames(vals), dt.keyFields));
            
            % replacing above with this for speed:
            keyFields = dt.keyFields;
            row = dt.table(idx);
            for i = 1:length(keyFields)
                field = keyFields{i};
                param.keyFields.(field) = row.(field);
            end
            
            param.additional = dt.getCacheParamForField(field);
        end

        function [validCache value timestamp] = retrieveCachedFieldValue(dt, iEntry, field)
            cacheName = dt.getCacheNameForFieldValue(field);
            cacheParam = dt.getCacheParamForFieldValue(iEntry, field);
            cacheTimestamp = dt.getCacheValidTimestampForField(field);

            cm = dt.getFieldValueCacheManager();
            validCache = cm.hasCacheNewerThan(cacheName, cacheParam, cacheTimestamp);

            if validCache
                [value timestamp] = cm.loadData(cacheName, cacheParam);
                %debug('Loading cached value for entry %d field %s\n', iEntry, field);
            else
                value = [];
                timestamp = NaN;
            end
        end

        function [validCache timestamp] = retrieveCachedFieldTimestamp(dt, iEntry, field)
            cacheName = dt.getCacheNameForFieldValue(field);
            cacheParam = dt.getCacheParamForFieldValue(iEntry, field);
            cacheTimestamp = dt.getCacheValidTimestampForField(field);

            cm = dt.getFieldValueCacheManager();
            [validCache timestamp] = cm.hasCacheNewerThan(cacheName, cacheParam, cacheTimestamp);
        end

        function timestamp = cacheFieldValue(dt, iEntry, field, varargin)
            p = inputParser;
            p.addRequired('iEntry', @(x) true); % @(x) isscalar(x) && x > 0 && x <= dt.nEntries);
            p.addRequired('field', @(x) true); % @(x) ischar(x) && dt.isField(field));
            p.addOptional('value', []); 
            p.parse(iEntry, field, varargin{:});
            if ismember('value', p.UsingDefaults)
                % use actual field value as default
                value = dt.select(iEntry).getValue(field);
            else
                value = p.Results.value;
            end

            cacheName = dt.getCacheNameForFieldValue(field);
            cacheParam = dt.getCacheParamForFieldValue(iEntry, field);
            cm = dt.getFieldValueCacheManager();
            %debug('Saving cache for entry %d field %s \n', iEntry, field);
            cm.saveData(cacheName, cacheParam, value);
        end

        function cacheAllValues(dt, fields, varargin)
            debug('Caching all loaded field values\n');
            p = inputParser;
            p.addOptional('fields', dt.fieldsCacheable, @iscellstr);
            p.parse(varargin{:});
            fields = intersect(p.Results.fields, dt.fieldsCacheable);

            for iEntry = 1:dt.nEntries
                for iField = 1:length(fields)
                    field = fields{iField};
                    % only cache if the value is loaded
                    if dt.loadedByEntry(iEntry).(field)
                        dt.cacheFieldValue(iEntry, field);
                    end
                end
            end
        end

        function deleteCachedFieldValues(dt, varargin)
            p = inputParser;
            p.addOptional('fields', dt.fieldsCacheable, @iscellstr);
            p.parse(varargin{:});
            fields = p.Results.fields;

            dt.assertIsField(fields);
            fields = intersect(fields, dt.fieldsCacheable);

            cm = dt.getFieldValueCacheManager();
            for iEntry = 1:dt.nEntries
                for iField = 1:length(fields)
                    field = fields{iField};
                    cacheName = dt.getCacheNameForFieldValue(field);
                    cacheParam = dt.getCacheParamForFieldValue(iEntry, field);
                    debug('Deleting cache for entry %d field %s\n', iEntry, field);
                    cm.deleteCache(cacheName, cacheParam);
                end
            end
        end
    end

    methods % Cacheable overrides
        function dt = prepareForCache(dt)
            % replace all loaded value with empty values to make cache loading very quick
            dt.warnIfNoArgOut(nargout);
            
            if dt.unloadCacheableFieldsPreCacheTable
                debug('Unloading all loadOnDemand field values pre-caching\n');
                dt = dt.unloadFields();
            end
        end

        % obj is the object newly loaded from cache, preLoadObj is the object 
        % as it existed before loading from the cache. Transfering data from obj
        % to preLoadObj will occur automatically for handle classes AFTER this
        % function is called. preLoadObj is provided only if there is information
        % in the object before calling loadFromCache that you would like to copy
        % to the cache-loaded object obj.
        function obj = postLoadFromCache(obj, param, timestamp, preLoadObj)
            % here we've loaded obj from the cache, but preLoadObj was the table that we
            % built in initialize by mapping the one-to-one table in the database.
            % Therefore we need to make sure that any entries which are present 
            % in preLoadObj but missing in obj are added to obj. We do this via
            % mergeEntriesWith
            obj = preLoadObj.mergeEntriesWith(obj, 'keyFieldMatchesOnly', true);
        end

        function deleteCache(dt)
            % delete caches for individual fields as well
            dt.deleteCachedFieldValues();
            deleteCache@StructTable(dt);
        end

        function cache(dt, varargin)
            p = inputParser;
            p.addOptional('cacheValues', true, @islogical);
            p.parse(varargin{:});
            cacheValues = p.Results.cacheValues;
            if cacheValues
                dt.cacheAllValues(dt);
            end
            cache@StructTable(dt);
        end
    end
end
