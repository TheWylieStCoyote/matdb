classdef HTMLDataTableWriter < HTMLReportWriter

    properties
        valueStruct
        columnAttrMap
        fields
        table

        indexColumnBackground = '#fafafa';
        keyFieldColumnBackground = '#def1fc';
    end

    methods
        function html = HTMLDataTableWriter(varargin)
            html = html@HTMLReportWriter(varargin{:});
        end

        function writeDataTable(html, varargin)
            html.buildValueStruct();

            html.buildColumnAttrMap();

            html.openDivRow();
            html.openDivSpan(12);

            html.openTable('class', 'table table-condensed table-hover table-bordered');

            html.writeFieldHeaderRow();
            
            % write entry rows
            html.openTableBody();

            nEntries = length(html.valueStruct); 
            for iEntry = 1:nEntries
                entry = html.valueStruct(iEntry);
                html.writeEntryRow(entry);
            end

            html.closeTableBody();
            html.closeTable();
            html.closeDivSpan();
            html.closeDivRow();
        end

        function buildValueStruct(html);
            html.valueStruct = html.table.getFullEntriesAsStringsAsStruct();
            html.fields = [{'index'}; makecol(fieldnames(html.valueStruct))];
            html.valueStruct = assignIntoStructArray(html.valueStruct, 'index', arrayfun(@num2str, 1:length(html.valueStruct), ...
                'UniformOutput', false));
        end

        function buildColumnAttrMap(html)
            % color extra fields differently
            html.columnAttrMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
            html.columnAttrMap('index') = {'style', sprintf('background-color: %s;', ...
                html.indexColumnBackground)};
            for iKeyField = 1:length(html.table.keyFields)
                field = html.table.keyFields{iKeyField};
                html.columnAttrMap(field) = {'style', sprintf('background-color: %s;', ...
                    html.keyFieldColumnBackground)};
            end
        end

        function str = getTooltipForField(html, field)
            if html.table.isField(field)
                % build a tooltip for this field on the th tag
                if html.table.isKeyField(field)
                    keyFieldStr = '<span class=''label label-info''>Key Field</span> ';
                else
                    keyFieldStr = '';
                end
                dfdDesc = html.table.fieldDescriptorMap(field).describe();
                str = sprintf('%s%s', keyFieldStr, dfdDesc);
            elseif strcmp(field, 'index')
                str = 'Entry index in the DataTable';
            else
                str = '';
            end
        end

        function writeFieldHeaderRow(html);
            % write fields in header
            html.openTableHead();
            html.openTableRow();
            fields =html.fields;
            nFields = length(fields);

            % write th tags with field headers
            for i = 1:nFields
                field = fields{i};

                if html.columnAttrMap.isKey(field)
                    extras = html.columnAttrMap(field);
                    if ~iscell(extras)
                        extras = {extras};
                    end
                else
                    extras = {};
                end

                tooltipHtml = html.getTooltipForField(field);
                if ~isempty(tooltipHtml)
                    html.openTag('th', extras{:});
                    html.writeTag('span', field, 'rel', 'tooltip', 'title', tooltipHtml, 'data-html', 'true');
                    html.closeTag('th');
                else
                    html.writeTag('th', field, extras{:});
                end
            end
            html.closeTableRow();
            html.closeTableHead();
        end

        function writeEntryRow(html, entry)
            fields = html.fields;
            html.openTableRow();
            for iField = 1:length(fields)
                field = fields{iField};
                if html.columnAttrMap.isKey(field)
                    extras = html.columnAttrMap(field);
                    if ~iscell(extras)
                        extras = {extras};
                    end
                else
                    extras = {};
                end
                html.openTableCell(extras{:});
                html.writeTag('div', ansiToHtml(entry.(field)), 'class', 'ellipsis'); 
                html.closeTableCell();
            end

            html.closeTableRow();
        end

        function generate(html, table)
            html.table = table;

            % generate report options
            html.pageTitle = table.entryNamePlural;
            html.mainHeader = table.entryNamePlural; 
            html.subHeader = sprintf('DataTable %s has %d entries.', table.entryName, table.nEntries);
            html.navTitle = 'Data Table';
            html.navSubTitle = table.entryNamePlural;

            html.openFile();
            html.writeHeader();

            html.writeDataTable(table);

            html.writeFooter();
            html.closeFile();
        end

    end
end

