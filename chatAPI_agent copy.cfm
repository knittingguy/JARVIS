    <cfheader name="Content-Type" value="application/json; charset=utf-8">
    <cfheader name="Access-Control-Allow-Origin" value="*">
    <cfheader name="Access-Control-Allow-Methods" value="POST, GET, OPTIONS">
    <cfheader name="Access-Control-Allow-Headers" value="Content-Type">

<cfscript>
    local.response = {
        success: false,
        message: "",
        error: "",
        results: [],
        answer: ""
    };

    try {
        if (CGI.REQUEST_METHOD EQ "OPTIONS") {
            cfheader(statuscode="200");
            writeOutput(serializeJSON({"status": "ok"}));
            return;
        }

        if (CGI.REQUEST_METHOD NEQ "POST") {
            cfheader(statuscode="405");
            local.response.error = "Method not allowed. Use POST.";
            writeOutput(serializeJSON(local.response));
            return;
        }

        local.requestBody = getHttpRequestData(true);
        local.data = deserializeJSON(local.requestBody.content);

        if (!structKeyExists(local.data, "message") OR len(trim(local.data.message)) EQ 0) {
            cfheader(statuscode="400");
            local.response.error = "Message is required";
            writeOutput(serializeJSON(local.response));
            return;
        }

        local.openAIKey = "";

        local.vectorStoreClient = vectorStore({
            provider: "qdrant",
            dimension: 1536,
            url: "http://localhost:6334",
            collectionName: "jarvis_cf_stripe_codebase",
            metricType: "COSINE",
            embeddingModel: {
                provider: "openai",
                modelName: "text-embedding-3-small",
                dimension: 1536,
                apiKey: local.openAIKey
            }
        });

        local.searchResults = local.vectorStoreClient.search({
            text: local.data.message,
            topK: 5,
            minScore: 0.3
        });

        local.hits = [];
        if (isArray(local.searchResults)) {
            local.hits = local.searchResults;
        } else if (isStruct(local.searchResults) and structKeyExists(local.searchResults, "hits") and isArray(local.searchResults.hits)) {
            local.hits = local.searchResults.hits;
        }

        local.contextBlocks = [];
        for (local.i = 1; local.i <= arrayLen(local.hits); local.i++) {
            local.hit = local.hits[local.i];
            local.fileName = "Unknown file";
            local.codeChunk = "";
            local.score = 0;

            if (isStruct(local.hit)) {
                if (structKeyExists(local.hit, "score") && isNumeric(local.hit.score)) {
                    local.score = local.hit.score;
                }

                if (structKeyExists(local.hit, "metadata") && isStruct(local.hit.metadata)) {
                    if (structKeyExists(local.hit.metadata, "file_path")) {
                        local.fileName = local.hit.metadata.file_path;
                    } else if (structKeyExists(local.hit.metadata, "path")) {
                        local.fileName = local.hit.metadata.path;
                    } else if (structKeyExists(local.hit.metadata, "source")) {
                        local.fileName = local.hit.metadata.source;
                    }
                }

                if (structKeyExists(local.hit, "codechunk")) {
                    local.codeChunk = local.hit.codechunk;
                } else if (structKeyExists(local.hit, "chunk")) {
                    local.codeChunk = local.hit.chunk;
                } else if (structKeyExists(local.hit, "text")) {
                    local.codeChunk = local.hit.text;
                }
            }

            if (!len(trim(local.codeChunk)) && isStruct(local.hit) && structKeyExists(local.hit, "payload") && isStruct(local.hit.payload)) {
                if (structKeyExists(local.hit.payload, "codechunk")) {
                    local.codeChunk = local.hit.payload.codechunk;
                } else if (structKeyExists(local.hit.payload, "text")) {
                    local.codeChunk = local.hit.payload.text;
                }
            }

            arrayAppend(local.response.results, {
                file: local.fileName,
                score: local.score,
                codechunk: local.codeChunk
            });

            if (len(trim(local.codeChunk))) {
                arrayAppend(local.contextBlocks, "File: " & local.fileName & chr(10) & "Code excerpt:" & chr(10) & local.codeChunk);
            }
        }

        if (arrayLen(local.contextBlocks) GT 0) {
            local.chatConfig = {
                PROVIDER: "openAi",
                APIKEY: local.openAIKey,
                MODELNAME: "gpt-4o-mini",
                TEMPERATURE: 0.2,
                MAXTOKENS: 800
            };

            local.chatModel = ChatModel(local.chatConfig);
            local.agent = Agent({
                CHATMODEL: local.chatModel
            });

            local.systemPrompt = "You are a helpful project assistant. Answer using only the retrieved code context supplied by the user. If the context does not provide enough information, say so clearly and do not invent facts. Cite file names when relevant.";
            local.userPrompt = "User question: " & local.data.message & chr(10) & chr(10) & "Retrieved context:" & chr(10) & arrayToList(local.contextBlocks, chr(10) & chr(10));

            local.chatRequest = {
                SYSTEMMESSAGE: local.systemPrompt,
                USERMESSAGE: {
                    MESSAGE: local.userPrompt
                }
            };

            local.aiResponse = local.agent.chat(local.chatRequest);

            if (isSimpleValue(local.aiResponse)) {
                local.response.answer = trim(local.aiResponse);
            } else if (isStruct(local.aiResponse)) {
                if (structKeyExists(local.aiResponse, "answer") && isSimpleValue(local.aiResponse.answer)) {
                    local.response.answer = trim(local.aiResponse.answer);
                } else if (structKeyExists(local.aiResponse, "message") && isSimpleValue(local.aiResponse.message)) {
                    local.response.answer = trim(local.aiResponse.message);
                } else if (structKeyExists(local.aiResponse, "content") && isSimpleValue(local.aiResponse.content)) {
                    local.response.answer = trim(local.aiResponse.content);
                } else if (structKeyExists(local.aiResponse, "text") && isSimpleValue(local.aiResponse.text)) {
                    local.response.answer = trim(local.aiResponse.text);
                } else if (structKeyExists(local.aiResponse, "output") && isSimpleValue(local.aiResponse.output)) {
                    local.response.answer = trim(local.aiResponse.output);
                } else {
                    local.response.answer = trim(serializeJSON(local.aiResponse));
                }
            } else if (isArray(local.aiResponse) && arrayLen(local.aiResponse)) {
                local.response.answer = trim(serializeJSON(local.aiResponse));
            }

            if (!len(trim(local.response.answer))) {
                local.response.answer = "I could not find enough relevant context in the codebase to answer that question.";
            }

            local.response.success = true;
            local.response.message = "Semantic search complete and answer generated by Agent().";
        } else {
            local.response.success = true;
            local.response.message = "Semantic search complete. No relevant code chunks were found.";
            local.response.answer = "I couldn't find relevant code snippets for that question in the project.";
        }

        cfheader(statuscode="200");

    } catch (any e) {
        cfheader(statuscode="500");
        local.response.success = false;
        local.response.error = "Search error: " & e.message;
    }

    writeOutput(serializeJSON(local.response));
</cfscript>
