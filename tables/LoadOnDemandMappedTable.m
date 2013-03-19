classdef LoadOnDemandMappedTable < StructTable
% This table type is useful for referencing data that is linked via a one-to-one
% relationship with another table, but is very large and should only be loaded
% when necessary and typically one or a few entries at a time
%
% This table type is abstract, and classes which override it must define the 
% specific fields which will be loaded, and a function which returns the
% loaded values of these fields for a specific entry, i.e. loads the values.

    properties
        % ignore cached field values earlier than this date
        fieldValueCacheValidAfterTimestamp = -Inf;

        % fields in this table may be returned by getFieldsCacheable meaning that their values
        % are stored in individual cache entries. When cacheing the entire table as a whole, 
        % it makes sense to unload these values automatically before saving the table down
        % so that the file size doesn't include the values of these fields which are duplicated
        % elsewhere
        unloadCacheableFieldsPreCacheTable = true;
        
        % set to true after initialize is run, which happens automatically in the 
        % constructor if a database argument is provided
        initialized = false;
    end

    properties(Dependent)
        fieldsLoadOnDemand
        fieldsLoadOnDemandDescriptorMap
        fieldsCacheable % subset of fieldsLoadOnDemand
        fieldsCacheableDescriptorMap
        fieldsRequestable
        
        cacheFieldsIndividually
    end
    
    properties(Access=protected)
        cachedFieldsLoadOnDemand
        cachedFieldsLoadOnDemandDescriptorMap 

        % these must be subsets of fieldsLoadOnDemand
        cachedFieldsCacheable 
        cachedFieldsRequestable

        % these are typical fields that are cached with the table 
        cachedFieldsNotLoadOnDemand
        cachedFieldsNotLoadOnDemandDescriptorMap

        cachedCacheManager
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
            cm = dt.cachedCacheManager;
        end
        
        % if true, cacheable fields are written to the cache individually
        % if false, all cacheable fields are written to the cache collectively by entry
        function tf = getCacheFieldsIndividually(dt)
            tf = true;
        end

        % return a list of fields that we can call loadValuesForEntry for
        % if a field is not listed here, it is presumably cacheable, and we won't try
        % to request the value if a cached value does not exist. That is, the cached value
        % must come from somewhere else and be set using setFieldValue().
        function fields = getFieldsRequestable(dt)
            fields = dt.getFieldsLoadOnDemand();
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
        
        function tf = get.cacheFieldsIndividually(dt)
            tf = dt.getCacheFieldsIndividually();
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
            
            % if true, keep any field values that are currently loaded in the database
            p.addParamValue('keepCurrentValues', false, @islogical);
            p.parse(varargin{:});
            
            db = p.Results.database;
            table = p.Results.table;
            fieldsLoaded = p.Results.fieldsLoaded;
            entryName = p.Results.entryName;
            entryNamePlural = p.Results.entryNamePlural;
            keepCurrentValues = p.Results.keepCurrentValues;
            
            if isempty(db) && isempty(table)
                if isempty(dt.database)
                    error('Please provide "database" param in order to lookup mapped table or "table" param directly');
                else
                    db = dt.database;
                end
            end

            if isempty(entryName)
                [entryName entryNamePlural] = dt.getEntryName();
            else
                if isempty(entryNamePlural)
                    entryNamePlural = [entryName 's'];
                end
            end
            
            % keep a copy of the original table in case we need to merge entries with it later
            dtOriginal = dt;

            if isempty(table)
                % no table specified, build it via mapping one-to-one off database table
                entryNameMap = dt.getMapsEntryName(); 
                debug('Mapping LoadOnDemand table off table %s\n', entryNameMap);
                table = db.getTable(entryNameMap).keyFieldsTable;
                
                table = table.setEntryName(entryName, entryNamePlural);
                
                % add additional fields
                [fields dfdMap] = dt.getFieldsNotLoadOnDemand();
                for iField = 1:length(fields)
                    field = fields{iField};
                    table = table.addField(field, [], 'fieldDescriptor', dfdMap(field));
                    table = table.applyFields();
                end

                % add load on demand fields
                [fields dfdMap] = dt.getFieldsLoadOnDemand();
                for iField = 1:length(fields)
                    field = fields{iField};
                    table = table.addField(field, [], 'fieldDescriptor', dfdMap(field));
                    table = table.applyFields();
                end
                
                fieldsLoaded = {};
            else
                error('When does this happen?');
                db = table.database;
                assert(~isempty(db), 'Table must be linked to a database');
            end
            
            % pre-cache all of the cachedFields* category lists so that 
            % the dependent properties all work    
            dt.cachedFieldsCacheable = dt.getFieldsCacheable();
            [fields, dfdMap] = dt.getFieldsLoadOnDemand();
            if isempty(fields)
                fields = {};
            end
            dt.cachedFieldsLoadOnDemand = fields;
            dt.cachedFieldsLoadOnDemandDescriptorMap = dfdMap;
            
            [fields, dfdMap] = dt.getFieldsNotLoadOnDemand();
            if isempty(fields)
                fields = {};
            end
            dt.cachedFieldsNotLoadOnDemand = fields;
            dt.cachedFieldsNotLoadOnDemandDescriptorMap = dfdMap;

            fields = dt.getFieldsRequestable();
            dt.cachedFieldsRequestable = fields;

            % initialize in StructTable 
            dt.table = [];
            dt = initialize@StructTable(dt, table, p.Unmatched); 

            % TODO replace this with default cache manager?
            dt.cachedCacheManager = MatdbSettingsStore.getDefaultCacheManager();
            
             % populate loadedByEntry and cacheTimestampsByEntry fields
            loadedByEntry = num2cell(dt.generateLoadedByEntry('fieldsLoaded', fieldsLoaded));
            dt = dt.addField('loadedByEntry', loadedByEntry, 'fieldDescriptor', UnspecifiedField); 
            cacheTimestampsByEntry = num2cell(dt.generateCacheTimestampsByEntry());
            dt = dt.addField('cacheTimestampsByEntry', cacheTimestampsByEntry, 'fieldDescriptor', UnspecifiedField); 
          
            %dt.loadedByEntry = dt.generateLoadedByEntry('fieldsLoaded', fieldsLoaded);
            %dt.cacheTimestampsByEntry = dt.generateCacheTimestampsByEntry();

            if keepCurrentValues
                % now dt has been mapped off of the table correctly, and dtOriginal holds certain
                % values that we'd like to hold onto, but only for specific entries that still 
                % exist within dt. Since the order of entries won't change, we don't need
                % to worry about loadedByEntry or cacheTimestampsByEntry changing
                dt = dt.mergeEntriesWith(dtOriginal, 'keyFieldMatchesOnly', true);
            end
            
            dt = db.addTable(dt);
            db.addRelationshipOneToOne(entryNameMap, entryName);
            dt.initialized = true;
            
            dt.updateInDatabase();
        end

        function dt = reinitialize(dt, varargin)
            dt.warnIfNoArgOut(nargout);
            dt = dt.initialize('keepCurrentValues', true);
        end

        % override to also call .initialize afterwards
        function dt = setDatabase(dt, database)
            dt.warnIfNoArgOut(nargout);

            oldDatabase = dt.database;
            dt = setDatabase@StructTable(dt, database);

            % initialize if not initialized yet or database is changing
            %if ~dt.initialized || ~isequal(oldDatabase, database)
            % dt = dt.initialize('keepCurrentValues', true);
            % end
        end
    end

    methods(Access=protected) % StructTable overrides
        % need to extend this in order to filter loadedByEntry appropriately
        %function dt = selectSortEntries(dt, indsInSortOrder)
        %    dt = selectSortEntries@StructTable(dt, indsInSortOrder);
        %    if ~isempty(dt.loadedByEntry) && isstruct(dt.loadedByEntry)
        %        dt.loadedByEntry = dt.loadedByEntry(indsInSortOrder, 1);
        %    end
        %    if ~isempty(dt.cacheTimestampsByEntry) && isstruct(dt.cacheTimestampsByEntry)
        %        dt.cacheTimestampsByEntry = dt.cacheTimestampsByEntry(indsInSortOrder, 1);
        %    end
        %end

        % need to extend this in order to add new rows to loadedByEntry appropriately
        function dt = subclassAddEntry(dt, S)
            if isempty(S(1).loadedByEntry)
                % assume that this doesn't come from a LoadOnDemandMappedTable
                % and therefore all of the values are "loaded" already
                loadedByEntry = dt.generateLoadedByEntry('fieldsLoaded', fieldnames(S), 'nEntries', length(S));
                S = structMerge(S, loadedByEntry);
            end
            if isempty(S(1).cacheTimestampsByEntry)
                cacheTimestampsByEntry = dt.generateCacheTimestampsByEntry('nEntries', length(S));
                S = structMerge(S, cacheTimestampsByEntry);
            end
            dt = subclassAddEntry@StructTable(dt, S);
        end
    end
    
    methods % Dependent properties
        function fields = get.fieldsLoadOnDemand(dt)
            fields = dt.cachedFieldsLoadOnDemand;
        end

        function fields = get.fieldsRequestable(dt)
            fields = dt.cachedFieldsRequestable;
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
            p.addParamValue('nEntries', dt.nEntries, @isscalar);
            p.parse(varargin{:});
            fieldsLoaded = p.Results.fieldsLoaded;
            nEntries = p.Results.nEntries;
            dt.assertIsField(fieldsLoaded);

            fieldsNotLoaded = setdiff(dt.fieldsLoadOnDemand, fieldsLoaded);
            loadedByEntry = emptyStructArray([nEntries 1], dt.fieldsLoadOnDemand);
            loadedByEntry = assignIntoStructArray(loadedByEntry, fieldsNotLoaded, false);
            loadedByEntry = assignIntoStructArray(loadedByEntry, fieldsLoaded, true); 
        end

        function cacheTimestampsByEntry = generateCacheTimestampsByEntry(dt, varargin)
            % build an initial value for the loadedByEntry struct array
            % for which loadedByEntry(iEntry).field is .NotLoaded for all fields
            % unless field is a member of param fieldsLoaded 
            p = inputParser;
            p.addParamValue('fieldsLoaded', {}, @iscellstr);
            p.addParamValue('nEntries', dt.nEntries, @isscalar);
            p.parse(varargin{:});
            fieldsLoaded = p.Results.fieldsLoaded;
            nEntries = p.Results.nEntries;
            dt.assertIsField(fieldsLoaded);
            cacheTimestampsByEntry = emptyStructArray([nEntries 1], dt.fieldsCacheable, 'value', NaN);
        end

        function allLoadedByEntry = getAllLoadedByEntry(dt, entryInd, varargin)
            % looks at entries(entryInd) and returns a logical array indicating 
            % whether all fieldsLoadOnDemand for that entry are currently loaded in the
            % database. entryInd defaults to all entries

            if nargin < 2
                entryInd = true(dt.nEntries, 1);
            end

            allLoadedFn = @(entry) all(structfun(@(x) x, entry.loadedByEntry));
            allLoadedByEntry = arrayfun(allLoadedFn, dt.table(entryInd));
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
            entryList = 1:dt.nEntries;
            entryList = entryList(entryMask);
            for iEntryCell = num2cell(entryList)
                iEntry = iEntryCell{1};
                
                progressStr = sprintf('[%5.1f %%]', 100 * loadedCount / nnz(entryMask));
                loadedCount = loadedCount + 1;

                % loaded.field is true if field is loaded already for this entry
                loaded = dt.table(iEntry).loadedByEntry;
                cacheTimestamps = dt.table(iEntry).cacheTimestampsByEntry;
                % to store loaded values for this entry
                loadedValues = struct();

                if reload 
                    % force reload of all fields
                    loaded = assignIntoStructArray(loaded, fieldnames(loaded), false);
                end

                % first, look up cacheable fields in cache
                if loadCache
                    hasPrintedMessage = false;

                    if dt.cacheFieldsIndividually
                        % load from cache each field for this entry
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
                                dt.table(iEntry).cacheTimestampsByEntry.(field) = timestamp;
                            end
                        end
                    else
                        % load cache all fields for entry together
                        allLoaded = true;
                        for field = fieldsCacheable
                            if ~loaded.(field{1})
                                % already loaded
                                allLoaded = false;
                                break;
                            end
                        end
                        
                        if ~allLoaded
                            fprintf('%s Retrieving cached fields for %s                \r', ...
                                progressStr, entryDescriptions{iEntry});
                            [validCache values timestamp] = dt.retrieveCachedValuesForEntry(iEntry, fieldsCacheable);
                            if validCache
                                % found cached values, store each field and mark as loaded
                                for iField = 1:length(fieldsCacheable)
                                    field = fieldsCacheable{iField};
                                    if isfield(values, field)
                                        loadedValues.(field) = values.(field);
                                        loaded.(field) = true;
                                        dt.table(iEntry).cacheTimestampsByEntry.(field) = timestamp;
                                    end
                                end
                            end
                        end
                        
                    end

                elseif loadCacheTimestampsOnly
                    hasPrintedMessage = false;
                    
                    if dt.cacheFieldsIndividually
                        % load from cache each field for this entry
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
                            dt.table(iEntry).cacheTimestampsByEntry.(field) = timestamp;
                        end
                    else
                        % load cache timestamp for entire entry's fields
                        allLoaded = true;
                        for iField = 1:length(fieldsCacheable)
                            field = fieldsCacheable{iField};
                            if ~loaded.(field)
                                % already loaded
                                allLoaded = false;
                                break;
                            end
                        end
                        fprintf('%s Retrieving cache timestamps for %s              \r', ...
                            progressStr, entryDescriptions{iEntry});
                        
                        [validCache timestamp] = dt.retrieveCachedTimestampForEntry(iEntry);
                        for iField = 1:length(fieldsCacheable)
                            field = fieldsCacheable{iField};
                            dt.table(iEntry).cacheTimestampsByEntry.(field) = timestamp;
                        end
                    end
                end

                % manually request the values of any remaining fields
                if ~loadCacheOnly
                    loadedMask = cellfun(@(field) loaded.(field), fields);
                    fieldsToRequest = fields(~loadedMask);
                    fieldsToRequest = intersect(fieldsToRequest, dt.fieldsRequestable);

                    if ~isempty(fieldsToRequest)
                        fprintf('%s Requesting value for entry %d fields %s            \r', ...
                            progressStr, iEntry, strjoin(fieldsToRequest, ', '));
                        thisEntry = dt.select(iEntry).apply();
                        mapEntryName = dt.getMapsEntryName();
                        mapEntry = thisEntry.getRelated(mapEntryName);
                        S = dt.loadValuesForEntry(mapEntry, fieldsToRequest);
                    
                        retFields = fieldnames(S);
                        
                        if dt.cacheFieldsIndividually
                            for iField = 1:length(retFields)
                                field = retFields{iField};
                                loadedValues.(field) = S.(field);
                                loaded.(field) = true;
                                if saveCache && ismember(field, fieldsCacheable)
                                    % cache the newly loaded value
                                    dt = dt.cacheFieldValue(iEntry, field, loadedValues.(field));
                                end
                            end
                        else
                            loadedValues = S;
                            entry = dt.table(iEntry);
                            entry = structMerge(entry, S);
                            dt = dt.cacheEntryAllFields(iEntry, entry);
                        end
                    end
                end
                

                % store the values in the table's fields
                loadedFields = intersect(fieldnames(loadedValues), dt.fieldsLoadOnDemand);

                if storeInTable
                    for iField = 1:length(loadedFields)
                        field = loadedFields{iField};
                        % no need to save cache here, already handled above
                        dt = dt.setFieldValue(iEntry, field, loadedValues.(field), ...
                            'saveCache', false);
                    end
                end

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
            
            progressStr = sprintf('[%5.1f %%]', 100);
            fprintf('%s Finished loading field values for %d entries            \n', ...
                            progressStr, length(entryList));

            dt = dt.apply();
            dt = dt.setAutoApply(savedAutoApply);
        end

        function value = retrieveValue(dt, field, varargin)
            assert(dt.nEntries == 1, 'retrieveValue only valid for single entries');
            [dt values] = dt.loadFields('fields', {field}, 'storeInTable', false, varargin{:});
            value = values.(field);
        end
        
        function dt = unloadFieldsForEntry(dt, entryMask, varargin)
            dt.warnIfNoArgOut(nargout);
            dt = dt.unloadFields('entryMask', entryMask, varargin{:});
        end

        function dt = unloadFields(dt, varargin)
            dt.warnIfNoArgOut(nargout);
            
            p = inputParser;
            p.addOptional('fields', dt.fieldsLoadOnDemand, @iscellstr);
            p.addOptional('entryMask', true(dt.nEntries, 1), @(x) isempty(x) || isvector(x));
            p.parse(varargin{:});
            fields = p.Results.fields;
            entryMask = p.Results.entryMask;

            % check fields okay
            validField = ismember(fields, dt.fieldsLoadOnDemand);
            assert(all(validField), 'Fields %s not found in fieldsLoadOnDemand', ...
                strjoin(fields(~validField)));

            % loop through entries, set fields to [] 
            % empty value will be converted to correct value via field descriptor
            entryInds = 1:dt.nEntries;
            entryInds = num2cell(entryInds(entryMask));
            for iEntryCell = entryInds
                iEntry = iEntryCell{1};
                for iField = 1:length(fields)
                    field = fields{iField}; 
                    % it's crucial here that when setting this value it is not cached
                    dt = dt.setFieldValue(iEntry, field, [], 'saveCache', false, ...
                        'markUnloaded', true);
                    dt.table(iEntry).loadedByEntry.(field) = false;
                end
            end
        end

        % augment the set field value method with one that automatically caches
        % the new value to disk
        function dt = setFieldValue(dt, idx, field, value, varargin)
            dt.warnIfNoArgOut(nargout);
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
                dt.table(idx).loadedByEntry.(field) = true;
            end
            if storeInTable && markUnloaded && ismember(field, dt.fieldsLoadOnDemand)
                dt.table(idx).loadedByEntry.(field) = false;
            end
            if saveCache && ismember(field, dt.fieldsCacheable)
                dt = dt.cacheFieldValue(idx, field, value);
            end
        end
        
        function dt = updateEntry(dt, idx, entry, varargin)
            % set fields for an entire entry at once, with flags that work like
            % setFieldValue above
            
            fields = fieldnames(entry);
            if dt.cacheFieldsIndividually
                % nothing to be gained here, do it individually by field
                for i = 1:length(fields)
                    dt = dt.setFieldValue(dt, idx, fields{i}, entry.(fields{i}), varargin{:});
                end
            else
                % cache the whole row at once
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
                    % Calling updateEntry will inadvertently trigger a
                    % cache save by calling setFieldValue with no
                    % arguments. So we manually reimplement it here.
                    %dt = updateEntry@StructTable(dt, idx, entry);
                    
                    if isa(entry, 'DataTable')
                        entry = entry.getFullEntriesAsStruct();
                    end

                    assert(length(entry) == 1, 'Currently only supported for single entries');
                    assert(isscalar(idx) && isnumeric(idx) && idx > 0 && idx <= dt.nEntries, ...
                        'Index invalid or out of range [0 nEntries]');

                    fields = intersect(dt.fields, fieldnames(entry));
                    for field = fields 
                        dt = dt.setFieldValue(idx, field{1}, entry.(fields{1}), ...
                            'saveCache', false, 'storeInTable', true, 'markLoaded', true);
                    end
                end
                
                fieldsLoadOnDemand = intersect(fields, dt.fieldsLoadOnDemand);
                if storeInTable && markLoaded  
                    for i = 1:length(fieldsLoadOnDemand)
                        dt.table(idx).loadedByEntry.(fieldsLoadOnDemand{i}) = true;
                    end
                end
                if storeInTable && markUnloaded 
                    for i = 1:length(fieldsLoadOnDemand)
                        dt.table(idx).loadedByEntry.(fieldsLoadOnDemand{i}) = false;
                    end
                end
                fieldsCacheable = intersect(fields, dt.fieldsCacheable);
                if saveCache 
                    dt = dt.cacheEntryAllFields(idx, entry);
                end
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
            cm = dt.getFieldValueCacheManager();
            if dt.cacheFieldsIndividually
                cacheName = dt.getCacheNameForFieldValue(field);
                cacheParam = dt.getCacheParamForFieldValue(iEntry, field);
                cacheTimestamp = dt.getCacheValidTimestampForField(field);
                
                validCache = cm.hasCacheNewerThan(cacheName, cacheParam, cacheTimestamp);
                if validCache
                    [value timestamp] = cm.loadData(cacheName, cacheParam);
                    %debug('Loading cached value for entry %d field %s\n', iEntry, field);
                else
                    value = [];
                    timestamp = NaN;
                end
            else
                [validCache values timestamp] = dt.retrieveCachedValuesForEntry(iEntry, {field});
                if validCache && isfield(values, field)
                    value = values.(field);
                else
                    value = [];
                    timestamp = NaN;
                end
            end
        end

        function [validCache timestamp] = retrieveCachedFieldTimestamp(dt, iEntry, field)
            if dt.cacheFieldsIndividually
                cacheName = dt.getCacheNameForFieldValue(field);
                cacheParam = dt.getCacheParamForFieldValue(iEntry, field);
                cacheTimestamp = dt.getCacheValidTimestampForField(field);

                cm = dt.getFieldValueCacheManager();
                [validCache timestamp] = cm.hasCacheNewerThan(cacheName, cacheParam, cacheTimestamp);
            else
                [validCache timestamp] = dt.retrieveCachedTimestampForEntry(iEntry);
            end
        end

        function dt = cacheFieldValue(dt, iEntry, field, varargin)
            dt.warnIfNoArgOut(nargout);
            
            p = inputParser;
            p.addRequired('iEntry', @(x) true); % @(x) isscalar(x) && x > 0 && x <= dt.nEntries);
            p.addRequired('field', @ischar); % @(x) ischar(x) && dt.isField(field));
            p.addOptional('value', '', @(x) true); 
            p.parse(iEntry, field, varargin{:});
            
            cm = dt.getFieldValueCacheManager();
            if dt.cacheFieldsIndividually
                cacheName = dt.getCacheNameForFieldValue(field);
                cacheParam = dt.getCacheParamForFieldValue(iEntry, field);
                
                if ismember('value', p.UsingDefaults)
                    % use actual field value as default
                    value = dt.select(iEntry).getValue(field);
                else
                    % use passed value
                    value = p.Results.value;
                end

                %debug('Saving cache for entry %d field %s \n', iEntry, field);
                timestamp = cm.saveData(cacheName, cacheParam, value);
                dt.table(iEntry).cacheTimestampsByEntry.(field) = timestamp;
            else
                debug('WARNING: Attempting to cache individual field value when fields are cached by entry\n');
                values = dt.table(iEntry);
                if ~ismember('value', p.UsingDefaults)
                    values.(field) = p.Results.value;
                end 
                dt = dt.cacheEntryAllFields(iEntry, values);
            end
        end

        function dt = cacheAllValues(dt, fields, varargin)
            dt.warnIfNoArgOut(nargout);
            
            debug('Caching all loaded field values\n');
            p = inputParser;
            p.addOptional('fields', dt.fieldsCacheable, @iscellstr);
            p.parse(varargin{:});
            fields = intersect(p.Results.fields, dt.fieldsCacheable);

            for iEntry = 1:dt.nEntries
                if dt.cacheFieldsIndividually
                    for iField = 1:length(fields)
                        field = fields{iField};
                        % only cache if the value is loaded
                        if dt.table(iEntry).loadedByEntry.(field)
                            dt = dt.cacheFieldValue(iEntry, field);
                        end
                    end
                else
                    % cache all fields at once
                    dt = dt.cacheEntryAllFields(iEntry);
                end
            end
        end

        function dt = deleteCachedFieldValues(dt, varargin)
            dt.warnIfNoArgOut(nargout);
            
            p = inputParser;
            p.addOptional('fields', dt.fieldsCacheable, @iscellstr);
            p.parse(varargin{:});
            fields = p.Results.fields;

            dt.assertIsField(fields);
            fields = intersect(fields, dt.fieldsCacheable);

            cm = dt.getFieldValueCacheManager();
            for iEntry = 1:dt.nEntries
                if dt.cacheFieldsIndividually
                    for iField = 1:length(fields)
                        field = fields{iField};
                        cacheName = dt.getCacheNameForFieldValue(field);
                        cacheParam = dt.getCacheParamForFieldValue(iEntry, field);
                        %debug('Deleting cache for entry %d field %s\n', iEntry, field);
                        cm.deleteCache(cacheName, cacheParam);
                        
                        dt.table(iEntry).cacheTimestampsByEntry.(field) = NaN;
                    end
                else
                    cacheName = dt.getCacheNameForEntryAllFields();
                    cacheParam = dt.getCacheParamForEntryAllFields(iEntry);
                    %debug('Deleting cache for entry %d all cacheable fields\n', iEntry);
                    cm.deleteCache(cacheName, cacheParam);
                    
                    for iField = 1:length(fields)
                        dt.table(iEntry).cacheTimestampsByEntry.(fields{iField}) = NaN;
                    end
                end
            end
        end
    end

    methods % Caching cacheable fields for entire entries (when cacheFieldsIndividually == false)
        function name = getCacheNameForEntryAllFields(dt)
            name = sprintf('%s_entries', dt.getCacheName());
        end

        % build the cache param to be used for field field on entry idx
        % this includes the manually specified params as well as the keyFields
        % of entry idx
        function param = getCacheParamForEntryAllFields(dt, idx)
            keyFields = dt.keyFields;
            % direct table access for speed, ideally would use get key fields table
            row = dt.table(idx);
            for i = 1:length(keyFields)
                field = keyFields{i};
                param.keyFields.(field) = row.(field);
            end
            
            param.table = dt.getCacheParam();
        end

        function timestamp = getCacheValidTimestampForEntryAllFields(dt)
            fieldsCacheable = dt.fieldsCacheable;
            timestamps = cellfun(@(field) dt.getCacheValidTimestampForField(field), fieldsCacheable);
            timestamp = max(timestamps);    
        end

        function [validCache values timestamp] = retrieveCachedValuesForEntry(dt, iEntry, fields)
            if nargin < 3
                % default to grabbing all fields at once
                fields = {};
            end
            if ~iscell(fields)
                fields = {fields};
            end
            cacheName = dt.getCacheNameForEntryAllFields();
            cacheParam = dt.getCacheParamForEntryAllFields(iEntry);
            cacheTimestamp = dt.getCacheValidTimestampForEntryAllFields();

            cm = dt.getFieldValueCacheManager();
            validCache = cm.hasCacheNewerThan(cacheName, cacheParam, cacheTimestamp);

            if validCache
                [values timestamp] = cm.loadData(cacheName, cacheParam, 'fields', fields);
                %debug('Loading cached value for entry %d field %s\n', iEntry, field);
            else
                values = struct();
                timestamp = NaN;
            end
        end
        
        function [validCache timestamp] = retrieveCachedTimestampForEntry(dt, iEntry)
            cacheName = dt.getCacheNameForEntryAllFields();
            cacheParam = dt.getCacheParamForEntryAllFields(iEntry);
            cacheTimestamp = dt.getCacheValidTimestampForEntryAllFields();

            cm = dt.getFieldValueCacheManager();
            [validCache timestamp] = cm.hasCacheNewerThan(cacheName, cacheParam, cacheTimestamp);
        end
        
        function dt = cacheEntryAllFields(dt, iEntry, row)
            dt.warnIfNoArgOut(nargout);
            
            fieldsCacheable = dt.fieldsCacheable;
            nonCacheable = setdiff(dt.fields, dt.fieldsCacheable);

            if nargin < 3
                row = dt.table(iEntry); 

                % determine whether this row is entirely loaded
                loaded = dt.table(iEntry).loadedByEntry;
                maskLoaded = structfun(@(x) x, loaded);
                if ~any(maskLoaded)
                    return;
                end
                
                 if ~all(maskLoaded)
                    fields = fieldnames(loaded);
                    fieldsNotLoaded = fieldsLoaded(~maskLoaded);

                    debug('WARNING: Caching entry with fields %s not loaded. Loading now', ...
                        strjoin(fieldsNotLoaded, ','));
                    dt = dt.loadFields('entryMask', iEntry, 'fields', fieldsNotLoaded); 
                 end
            end

            row = rmfield(row, intersect(fieldnames(row), nonCacheable));

            %debug('Saving cache for entry %d all cacheable fields\n', iEntry);
            cm = dt.getFieldValueCacheManager();
            cacheName = dt.getCacheNameForEntryAllFields();
            cacheParam = dt.getCacheParamForEntryAllFields(iEntry);
            
            % save the values as separate fields in the .mat file, to facilitate
            % easy partial loading of specific fields
            timestamp = cm.saveData(cacheName, cacheParam, row, 'separateFields', true);
            
            % update cache timestamps
            for iField = 1:length(fieldsCacheable)
                dt.table(iEntry).cacheTimestampsByEntry.(fieldsCacheable{iField}) = timestamp;
            end    
        end
    end

    methods % Cacheable overrides
        function dt = prepareForCache(dt, varargin)
            p = inputParser;
            p.addParamValue('snapshot', false, @islogical);  
            p.KeepUnmatched = true;
            p.parse(varargin{:});
            snapshot = p.Results.snapshot;
            
            % replace all loaded value with empty values to make cache loading very quick
            dt.warnIfNoArgOut(nargout);
            
            if ~snapshot && dt.unloadCacheableFieldsPreCacheTable
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
        function obj = postLoadFromCache(obj, param, timestamp, preLoadObj, varargin)
            % here we've loaded obj from the cache, but preLoadObj was the table that we
            % built in initialize by mapping the one-to-one table in the database.
            % Therefore we need to make sure that any entries which are present 
            % in preLoadObj but missing in obj are added to obj. We do this via
            % mergeEntriesWith
            
            p = inputParser;
            p.addParamValue('snapshot', false, @islogical);  
            p.parse(varargin{:});
            snapshot = p.Results.snapshot;

            if ~isempty(preLoadObj.database)
               obj.setDatabase(preLoadObj.database);
            end
            
            if preLoadObj.initialized
                % if the table we're loading into is already initialized (and thus mapped to the
                % database), then we want to merge in entries from the snapshot into this table
                % so that the mapping aspect is preserved but the values are from the snapshot.
                obj = preLoadObj.mergeEntriesWith(obj, 'keyFieldMatchesOnly', true);
            else
                % if we haven't been initialized, then just use the snapshot directly
                % as merging won't accomplish anything
                obj = preLoadObj;    
            end
        end

        function dt = deleteCache(dt)
            dt.warnIfNoArgOut(nargout);
            
            % delete caches for individual fields as well
            dt = dt.deleteCachedFieldValues();
            deleteCache@StructTable(dt);
        end

        function dt = cache(dt, varargin)
            dt.warnIfNoArgOut(nargout);
      
            p = inputParser;
            p.addOptional('cacheValues', true, @islogical);
            p.parse(varargin{:});
            cacheValues = p.Results.cacheValues;
            if cacheValues
                dt = dt.cacheAllValues(dt);
            end
            cache@StructTable(dt);
        end
    end
end
