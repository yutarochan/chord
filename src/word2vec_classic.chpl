// The following is a "lexical" translation of the classic word2vec
// As this is a baseline for creating a distributed version of word2vec in Chapel,
// this translation biases towards lexical equivalence versus performance.
use Logging, Time;

const MAX_STRING = 100;
const EXP_TABLE_SIZE = 1000;
const MAX_EXP = 6;
const MAX_SENTENCE_LENGTH = 1000;
const MAX_CODE_LENGTH = 40;

const vocab_hash_size = 30000000;  // Maximum 30 * 0.7 = 21M words in the vocabulary

// Command line arguments
config var vocab_max_size = 1000;
config const min_count = 5;
config const train_file = "";
config const save_vocab_file = "";
config const read_vocab_file = "";
config const output_file: string = "";
config const hs = 0;
config const negative = 5;
config const iterations = 5;
config const window = 5;
config const cbow = 1;
config const binary = 0;
config const classes = 0;
config var alpha = 0.025 * 2;
config const sample = 1e-3;
config const size = 100;
config const debug_mode = 2;

const SPACE = ascii(' '): uint(8);
const TAB = ascii('\t'): uint(8);
const CRLF = ascii('\n'): uint(8);

const layer1_size = size;
const LayerSpace = {0..#layer1_size};

const num_threads = here.maxTaskPar;

class VocabWord {
  var len: int = MAX_STRING;
  var word: [0..#len] uint(8);
}

class VocabTreeNode {
  var codelen: uint(8);
  var code: [0..#MAX_CODE_LENGTH] uint(8);
  var point: [0..#MAX_CODE_LENGTH] int;
}

record VocabEntry {
  var word: VocabWord = nil;
  var cn: int(64);
  var node: VocabTreeNode;
};

var vocab_size = 0;
var vocabDomain = {0..#vocab_max_size};
var vocab: [vocabDomain] VocabEntry;
var vocab_hash: [0..#vocab_hash_size] int = -1;

var syn0Domain = {0..#vocab_size*layer1_size};
var syn0: [syn0Domain] real;
var syn1Domain = {0..#1};
var syn1: [syn1Domain] real;
var syn1negDomain = {0..#1};
var syn1neg: [syn1negDomain] real;

var expTable: [0..#(EXP_TABLE_SIZE+1)] real;
var table_size: int = 1e8:int;
var table: [0..#table_size] int;

var train_words: int = 0;
var word_count_actual = 0;
var starting_alpha: real;
var min_reduce = 1;

var atCRLF = false;

proc InitUnigramTable() {
  var a, i: int;
  var d1, train_words_pow: real;
  var power: real = 0.75;
  for a in 0..#vocab_size do train_words_pow += vocab[a].cn ** power;
  i = 0;
  d1 = (vocab[i].cn ** power) / train_words_pow;
  for a in 0..#table_size {
    table[a] = i;
    if (a / table_size:real > d1) {
      i += 1;
      d1 += (vocab[i].cn ** power) / train_words_pow;
    }
    if (i >= vocab_size) then i = vocab_size - 1;
  }
}

inline proc readNextChar(ref ch: uint(8), reader): bool {
  if (atCRLF) {
    atCRLF = false;
    ch = CRLF;
    return true;
  }
  return reader.read(ch);
}

proc ReadWord(word: [?] uint(8), reader): int {
  var a: int;
  var ch: uint(8);

  while readNextChar(ch, reader) {
    if (ch == 13) then continue;
    if ((ch == SPACE) || (ch == TAB) || (ch == CRLF)) {
      if (a > 0) {
        // Readers do not have ungetc, so Simulate ungetc using the atCRLF flag
        if (ch == CRLF) then atCRLF = true;
        break;
      }
      if (ch == CRLF) then return writeSpaceWord(word);
                      else continue;
    }
    word[a] = ch;
    a += 1;
    if (a >= MAX_STRING - 1) then a -= 1; // Truncate too long words
  }
  return a;
}

inline proc GetWordHash(word: VocabWord): int {
  return GetWordHash(word.word, word.len);
}

inline proc GetWordHash(word: [?] uint(8), len: int): int {
  var hash: uint = 0;
  for ch in 0..#len do hash = hash * 257 + word[ch]: uint;
  hash = hash % vocab_hash_size: uint;
  return hash: int;
}

// Returns position of a word in the vocabulary; if the word is not found, returns -1
proc SearchVocab(word: [?D] uint(8), len: int): int {
  var hash = GetWordHash(word, len);

  while (1) {
    if (vocab_hash[hash] == -1) then return -1;
    var vw = vocab[vocab_hash[hash]].word;
    if (len == vw.len) {
      var found = true;
      for i in 0..#len {
        if (word[i] != vw.word[i]) {
          found = false;
          break;
        }
      }
      if found then return vocab_hash[hash];
    }
    hash = (hash + 1) % vocab_hash_size;
  }

  return -1;
}

proc ReadWordIndex(reader): int {
  var word: [0..#MAX_STRING] uint(8);
  var len = ReadWord(word, reader);
  if (len == 0) then return -2;
  return SearchVocab(word, len);
}

// Adds a word to the vocabulary
proc AddWordToVocab(word: [?D] uint(8), length: int): int {
  var len = if (length > MAX_STRING) then MAX_STRING else length;
  var vw = new VocabWord(len);
  for i in 0..#len do vw.word[i] = word[i];
  vocab[vocab_size].word = vw;
  vocab[vocab_size].cn = 0;
  vocab_size += 1;
  // Reallocate memory if needed
  if (vocab_size + 2 >= vocab_max_size) {
    // TODO: research if the original += 1000 is adequate performance-wise
    vocab_max_size *= 2;
    vocabDomain = {0..#vocab_max_size};
  }
  var hash = GetWordHash(word, len);
  while (vocab_hash[hash] != -1) {
    hash = (hash + 1) % vocab_hash_size;
  }
  vocab_hash[hash] = vocab_size - 1;
  return vocab_size - 1;
}

private inline proc chpl_sort_cmp(a, b, param reverse=false, param eq=false) {
  if eq {
    if reverse then return a >= b;
    else return a <= b;
  } else {
    if reverse then return a > b;
    else return a < b;
  }
}

proc InsertionSort(Data: [?Dom] VocabEntry, doublecheck=false, param reverse=false) where Dom.rank == 1 {
  const lo = Dom.low;
  for i in Dom {
    const ithVal = Data(i);
    var inserted = false;
    for j in lo..i-1 by -1 {
      if (chpl_sort_cmp(ithVal.cn, Data(j).cn, reverse)) {
        Data(j+1) = Data(j);
      } else {
        Data(j+1) = ithVal;
        inserted = true;
        break;
      }
    }
    if (!inserted) {
      Data(lo) = ithVal;
    }
  }
}

proc QuickSort(Data: [?Dom] VocabEntry, minlen=7, doublecheck=false, param reverse=false) where Dom.rank == 1 {
  // grab obvious indices
  const lo = Dom.low,
        hi = Dom.high,
        mid = lo + (hi-lo+1)/2;

  // base case -- use insertion sort
  if (hi - lo < minlen) {
    InsertionSort(Data, reverse=reverse);
    return;
  }

  // find pivot using median-of-3 method
  if (chpl_sort_cmp(Data(mid).cn, Data(lo).cn, reverse)) then Data(mid) <=> Data(lo);
  if (chpl_sort_cmp(Data(hi).cn, Data(lo).cn, reverse)) then Data(hi) <=> Data(lo);
  if (chpl_sort_cmp(Data(hi).cn, Data(mid).cn, reverse)) then Data(hi) <=> Data(mid);
  const pivotVal = Data(mid);
  Data(mid) = Data(hi-1);
  Data(hi-1) = pivotVal;
  // end median-of-3 partitioning

  var loptr = lo,
      hiptr = hi-1;
  while (loptr < hiptr) {
    do { loptr += 1; } while (chpl_sort_cmp(Data(loptr).cn, pivotVal.cn, reverse));
    do { hiptr -= 1; } while (chpl_sort_cmp(pivotVal.cn, Data(hiptr).cn, reverse));
    if (loptr < hiptr) {
      Data(loptr) <=> Data(hiptr);
    }
  }

  Data(hi-1) = Data(loptr);
  Data(loptr) = pivotVal;

  //  cobegin {
    QuickSort(Data[..loptr-1], reverse=reverse);  // could use unbounded ranges here
    QuickSort(Data[loptr+1..], reverse=reverse);
    //  }
}

proc SortVocab() {
  var a, size, hash: int;

  // Sort the vocabulary and keep </s> at the first position
  QuickSort(vocab[1..], vocab_size - 1, reverse=true);
  for a in 0..#vocab_hash_size do vocab_hash[a] = -1;
  size = vocab_size;
  train_words = 0;
  for a in 0..#size {
    // Words occuring less than min_count times will be discarded from the vocab
    if ((vocab[a].cn < min_count) && (a != 0)) {
      vocab_size -= 1;
      delete vocab[a].word;
      /*vocab[a].word = nil;
      vocab[a].cn = 0;*/
    } else {
      // Hash will be re-computed, as after the sorting it is not actual
      hash = GetWordHash(vocab[a].word);
      while (vocab_hash[hash] != -1) do hash = (hash + 1) % vocab_hash_size;
      vocab_hash[hash] = a;
      train_words += vocab[a].cn;
    }
  }
  vocabDomain = {0..#(vocab_size + 1)};
  // Allocate memory for the binary tree construction
  for a in 0..#vocab_size do vocab[a].node = new VocabTreeNode();
}

proc ReduceVocab() {
  var a, b: int;
  for a in 0..#vocab_size do if (vocab[a].cn > min_reduce) {
    vocab[b].cn = vocab[a].cn;
    vocab[b].word = vocab[a].word;
    b += 1;
  } else {
    delete vocab[a].word;
  }
  vocab_size = b;
  for a in 0..#vocab_hash_size do vocab_hash[a] = -1;
  for a in 0..#vocab_size {
    // Hash will be re-computed, as it is not actual
    var hash = GetWordHash(vocab[a].word);
    while (vocab_hash[hash] != -1) do hash = (hash + 1) % vocab_hash_size;
    vocab_hash[hash] = a;
  }
  min_reduce += 1;
}

proc CreateBinaryTree() {
  var b, i, min1i, min2i, pos1, pos2: int(64);
  var point: [0..#MAX_CODE_LENGTH] int(64);
  var code: [0..#MAX_CODE_LENGTH] uint(8);
  var dom = {0..#(vocab_size*2 + 1)};
  var count: [dom] int(64);
  var binary: [dom] int(64);
  var parent_node: [dom] int(64);
  count = 1e15: int(64);
  for a in 0..#vocab_size do count[a] = vocab[a].cn;
  pos1 = vocab_size - 1;
  pos2 = vocab_size;
  // Following algorithm constructs the Huffman tree by adding one node at a time
  for a in 0..#(vocab_size-1) {
    // First, find two smallest nodes 'min1, min2'
    if (pos1 >= 0) {
      if (count[pos1] < count[pos2]) {
        min1i = pos1;
        pos1 -= 1;
      } else {
        min1i = pos2;
        pos2 += 1;
      }
    } else {
      min1i = pos2;
      pos2 += 1;
    }
    if (pos1 >= 0) {
      if (count[pos1] < count[pos2]) {
        min2i = pos1;
        pos1 -= 1;
      } else {
        min2i = pos2;
        pos2 += 1;
      }
    } else {
      min2i = pos2;
      pos2 += 1;
    }
    count[vocab_size + a] = count[min1i] + count[min2i];
    parent_node[min1i] = vocab_size + a;
    parent_node[min2i] = vocab_size + a;
    binary[min2i] = 1;
  }
  // Now assign binary code to each vocabulary word
  for a in 0..#vocab_size {
    b = a;
    i = 0;
    while (1) {
      code[i] = binary[b]: uint(8);
      point[i] = b;
      i += 1;
      b = parent_node[b];
      if (b == vocab_size * 2 - 2) then break;
    }
    vocab[a].node.codelen = i: uint(8);
    vocab[a].node.point[0] = vocab_size - 2;
    for b in 0..#i {
      vocab[a].node.code[i - b - 1] = code[b];
      vocab[a].node.point[i - b] = point[b] - vocab_size;
    }
  }
}

proc LearnVocabFromTrainFile() {
  var word: [0..#MAX_STRING] uint(8);
  var i: int(64);
  var len: int;
  for a in 0..#vocab_hash_size do vocab_hash[a] = -1;
  var f = open(train_file, iomode.r);
  /*if (fin == NULL) {
    printf("ERROR: training data file not found!\n");
    exit(1);
  }*/
  var r = f.reader(kind=ionative, locking=false);
  vocab_size = 0;
  writeSpaceWord(word);
  AddWordToVocab(word, 4);
  while (1) {
    len = ReadWord(word, r);
    if (len == 0) then break;
    train_words += 1;
    if (debug_mode > 0 && (train_words % 100000 == 0)) {
      write(train_words / 1000, "K\r");
      stdout.flush();
    }
    i = SearchVocab(word, len);
    if (i == -1) {
      var a = AddWordToVocab(word, len);
      vocab[a].cn = 1;
    } else {
      vocab[i].cn += 1;
    }
    if (vocab_size > vocab_hash_size * 0.7) then ReduceVocab();
  }
  SortVocab();
  if (debug_mode > 0) {
    info("Vocab size: ", vocab_size);
    info("Words in train file: ", train_words);
  }
  r.close();
  f.close();
}

proc SaveVocab() {
  var f = open(save_vocab_file, iomode.cw);
  var w = f.writer(locking=false);
  for i in 0..#vocab_size {
    var vw = vocab[i].word;
    for j in 0..#vw.len do w.writef("%c", vw.word[j]);
    w.writeln(" ", vocab[i].cn);
  }
  w.close();
  f.close();
}

proc ReadVocab() {
  var a: int(64);
  var cn: int;
  var c: uint(8);
  var word: [0..#MAX_STRING] uint(8);

  var f = open(read_vocab_file, iomode.r);
  /*if (fin == NULL) {
    printf("Vocabulary file not found\n");
    exit(1);
  }*/
  var r = f.reader(kind=ionative);

  vocab_hash = -1;
  vocab_size = 0;
  train_words = 0;

  while (1) {
    var len = ReadWord(word, r);
    if (len == 0) then break;
    a = AddWordToVocab(word, len);
    // read and compute word count
    len = ReadWord(word, r);
    if (len == 0) then break;
    vocab[a].cn = wordToInt(word, len);
    train_words += vocab[a].cn;
    // skip CRLF
    ReadWord(word, r);
  }

  r.close();
  f.close();

  // NOTE: we don't SortVocab here because the vocab is already sorted when read
  if (debug_mode > 0) {
    writeln("Vocab size: ", vocab_size);
    writeln("Words in train file: ", train_words);
  }
  for a in 0..#vocab_size do vocab[a].node = new VocabTreeNode();
}

proc InitNet() {
  syn0Domain = {0..#vocab_size*layer1_size};
  if (hs) then syn1Domain = syn0Domain;
  if (negative > 0) then syn1negDomain = syn0Domain;
  var next_random: uint(64) = 1;
  for a in 0..#vocab_size {
    for b in LayerSpace {
      next_random = next_random * 25214903917:uint(64) + 11;
      syn0[a * layer1_size + b] = (((next_random & 0xFFFF) / 65536:real) - 0.5) / layer1_size;
    }
  }
  CreateBinaryTree();
}

proc TrainModelThread(tf: string, id: int) {
  var a, b, d, cw, word, last_word, sentence_length, sentence_position: int(64);
  var word_count, last_word_count: int(64);
  var sen: [0..#(MAX_SENTENCE_LENGTH + 1)] int;
  var l1, l2, c, target, labelx: int(64);
  var local_iter = iterations;
  var next_random: uint(64) = id:uint(64);
  var f, g: real;
  var t: Timer;
  var atEOF = false;

  var neu1: [LayerSpace] real;
  var neu1e: [LayerSpace] real;

  var trainFile = open(tf, iomode.r);
  var fileChunkSize = trainFile.length() / num_threads;
  var seekStart = fileChunkSize * id;
  var seekStop = fileChunkSize * (id + 1);
  var reader = trainFile.reader(kind = ionative, start=seekStart, end=seekStop, locking=false);

  t.start();
  const start = t.elapsed(TimeUnits.microseconds);

  while (1) {
    if (word_count - last_word_count > 10000) {
      word_count_actual += word_count - last_word_count;
      last_word_count = word_count;
      if (debug_mode > 1) {
        var now = t.elapsed(TimeUnits.milliseconds);
        writef("\rAlpha: %r  Progress: %0.3r%%  Words/thread/sec: %rk  ",
              alpha,
              (word_count_actual / (iterations * train_words + 1):real) * 100,
              word_count_actual / ((now - start + 1) / 1000) / 1000);
        stdout.flush();
      }
      alpha = starting_alpha * (1 - word_count_actual / (iterations * train_words + 1):real);
      if (alpha < starting_alpha * 0.0001) then alpha = starting_alpha * 0.0001;
    }
    if (sentence_length == 0) {
      while (1) {
        word = ReadWordIndex(reader);
        if (word == -2) {
          atEOF = true;
          break;
        }
        if (word == -1) then continue;
        word_count += 1;
        if (word == 0) then break;
        // The subsampling randomly discards frequent words while keeping the ranking same
        if (sample > 0) {
          var ran = (sqrt(vocab[word].cn / (sample * train_words):real) + 1) * (sample * train_words):real / vocab[word].cn;
          next_random = (next_random * 25214903917:uint(64) + 11):uint(64);
          if (ran < (next_random & 0xFFFF):real / 65536:real) then continue;
        }
        sen[sentence_length] = word;
        sentence_length += 1;
        if (sentence_length >= MAX_SENTENCE_LENGTH) then break;
      }
      sentence_position = 0;
    }
    if (atEOF || (word_count > train_words / num_threads)) {
      word_count_actual += word_count - last_word_count;
      local_iter -= 1;
      if (local_iter == 0) then break;
      word_count = 0;
      last_word_count = 0;
      sentence_length = 0;
      reader.close();
      reader = trainFile.reader(kind = ionative, start=seekStart, end=seekStop);
      atEOF = false;
      continue;
    }
    word = sen[sentence_position];
    if (word == -1) then continue;
    for c in LayerSpace {
      neu1[c] = 0;
      neu1e[c] = 0;
    }
    next_random = (next_random * 25214903917:uint(64) + 11):uint(64);
    b = (next_random % window: uint(64)):int(64);
    if (cbow) {  //train the cbow architecture
      // in -> hidden
      cw = 0;
      for a in b..(window * 2 - b) do if (a != window) {
        c = sentence_position - window + a;
        if (c < 0) then continue;
        if (c >= sentence_length) then continue;
        last_word = sen[c];
        if (last_word == -1) then continue;
        for c in LayerSpace do neu1[c] += syn0[c + last_word * layer1_size];
        cw += 1;
      }
      if (cw) {
        for c in LayerSpace do neu1[c] /= cw;
        if (hs) then for d in 0..#vocab[word].node.codelen {
          f = 0;
          l2 = vocab[word].node.point[d] * layer1_size;
          // Propagate hidden -> output
          for c in LayerSpace do f += neu1[c] * syn1[c + l2];
          if (f <= -MAX_EXP) then continue;
          else if (f >= MAX_EXP) then continue;
          else f = expTable[((f + MAX_EXP) * (EXP_TABLE_SIZE / MAX_EXP / 2)):int];
          // 'g' is the gradient multiplied by the learning rate
          g = (1 - vocab[word].node.code[d] - f) * alpha;
          // Propagate errors output -> hidden
          for c in LayerSpace do neu1e[c] += g * syn1[c + l2];
          // Learn weights hidden -> output
          for c in LayerSpace do syn1[c + l2] += g * neu1[c];
        }
        // NEGATIVE SAMPLING
        if (negative > 0) then for d in 0..#(negative + 1) {
          if (d == 0) {
            target = word;
            labelx = 1;
          } else {
            next_random = (next_random * 25214903917:uint(64) + 11):uint(64);
            target = table[((next_random >> 16) % table_size:uint(64)):int];
            if (target == 0) then target = (next_random % (vocab_size - 1):uint(64) + 1):int;
            if (target == word) then continue;
            labelx = 0;
          }
          l2 = target * layer1_size;
          f = 0;
          for c in LayerSpace do f += neu1[c] * syn1neg[c + l2];
          if (f > MAX_EXP) then g = (labelx - 1) * alpha;
          else if (f < -MAX_EXP) then g = (labelx - 0) * alpha;
          else g = (labelx - expTable[((f + MAX_EXP) * (EXP_TABLE_SIZE / MAX_EXP / 2)):int]) * alpha;
          for c in LayerSpace do neu1e[c] += g * syn1neg[c + l2];
          for c in LayerSpace do syn1neg[c + l2] += g * neu1[c];
        }
        // hidden -> in
        for a in b..(window * 2 - b) do if (a != window) {
          c = sentence_position - window + a;
          if (c < 0) then continue;
          if (c >= sentence_length) then continue;
          last_word = sen[c];
          if (last_word == -1) then continue;
          for c in LayerSpace do syn0[c + last_word * layer1_size] += neu1e[c];
        }
      }
    } else {  //train skip-gram
      for a in b..(window * 2 - b) do if (a != window) {
        c = sentence_position - window + a;
        if (c < 0) then continue;
        if (c >= sentence_length) then continue;
        last_word = sen[c];
        if (last_word == -1) then continue;
        l1 = last_word * layer1_size;
        for c in LayerSpace do neu1e[c] = 0;
        // HIERARCHICAL SOFTMAX
        if (hs) then for d in 0..#vocab[word].node.codelen {
          f = 0;
          l2 = vocab[word].node.point[d] * layer1_size;
          // Propagate hidden -> output
          for c in LayerSpace do f += syn0[c + l1] * syn1[c + l2];
          if (f <= -MAX_EXP) then continue;
          else if (f >= MAX_EXP) then continue;
          else f = expTable[((f + MAX_EXP) * (EXP_TABLE_SIZE / MAX_EXP / 2)):int];
          // 'g' is the gradient multiplied by the learning rate
          g = (1 - vocab[word].node.code[d] - f) * alpha;
          // Propagate errors output -> hidden
          for c in LayerSpace do neu1e[c] += g * syn1[c + l2];
          // Learn weights hidden -> output
          for c in LayerSpace do syn1[c + l2] += g * syn0[c + l1];
        }
        // NEGATIVE SAMPLING
        if (negative > 0) then for d in 0..#negative {
          if (d == 0) {
            target = word;
            labelx = 1;
          } else {
            next_random = (next_random * 25214903917:uint(64) + 11):uint(64);
            target = table[((next_random >> 16) % table_size:uint(64)):int];
            if (target == 0) then target = (next_random % (vocab_size - 1):uint(64) + 1):int;
            if (target == word) then continue;
            labelx = 0;
          }
          l2 = target * layer1_size;
          f = 0;
          for c in LayerSpace do f += syn0[c + l1] * syn1neg[c + l2];
          if (f > MAX_EXP) then g = (labelx - 1) * alpha;
          else if (f < -MAX_EXP) then g = (labelx - 0) * alpha;
          else g = (labelx - expTable[((f + MAX_EXP) * (EXP_TABLE_SIZE / MAX_EXP / 2)):int]) * alpha;
          for c in LayerSpace do neu1e[c] += g * syn1neg[c + l2];
          for c in LayerSpace do syn1neg[c + l2] += g * syn0[c + l1];
        }
        // Learn weights input -> hidden
        for c in LayerSpace do syn0[c + l1] += neu1e[c];
      }
    }
    sentence_position += 1;
    if (sentence_position >= sentence_length) {
      sentence_length = 0;
      continue;
    }
  }
  t.stop();
  reader.close();
  trainFile.close();
}

proc TrainModel() {
  var a, b, c, d: int;
  var t: Timer;

  info("Starting training using file ", train_file);
  starting_alpha = alpha;
  if (read_vocab_file != "") then ReadVocab(); else LearnVocabFromTrainFile();
  if (save_vocab_file != "") then SaveVocab();
  if (output_file == "") then return;
  InitNet();
  if (negative > 0) then InitUnigramTable();

  // run on a single locale using all threads available
  forall i in 0..#num_threads {
    TrainModelThread(train_file, i);
  }

  var outputFile = open(output_file, iomode.cw);
  var writer = outputFile.writer(locking=false);
  if (classes == 0) {
    // Save the word vectors
    writer.writeln(vocab_size, " ", layer1_size);
    for a in 0..#vocab_size {
      var vw = vocab[a].word;
      for j in 0..#vw.len {
        writer.writef("%c", vw.word[j]);
      }
      writer.write(" ");
      if (binary) then for b in LayerSpace do writer.writef("%|4r", syn0[a * layer1_size + b]);
      else for b in LayerSpace do writer.write(syn0[a * layer1_size + b], " ");
      writer.writeln();
    }
  } else {
    // Run K-means on the word vectors
    var clcn = classes;
    var iterX = 10;
    var closeid: int;
    var centcn: [0..#classes] int;
    var cl: [0..#vocab_size] int;
    var closev, x: real;
    var cent: [0..#classes*layer1_size] real;

    for a in 0..#vocab_size do cl[a] = a % clcn;
    for a in 0..iterX {
      for b in 0..#(clcn * layer1_size) do cent[b] = 0;
      for b in 0..#clcn do centcn[b] = 1;
      for c in 0..#vocab_size {
        for d in LayerSpace do cent[layer1_size * cl[c] + d] += syn0[c * layer1_size + d];
        centcn[cl[c]] += 1;
      }
      for b in 0..#clcn {
        closev = 0;
        for c in LayerSpace {
          cent[layer1_size * b + c] /= centcn[b];
          closev += cent[layer1_size * b + c] * cent[layer1_size * b + c];
        }
        closev = sqrt(closev);
        for c in LayerSpace do cent[layer1_size * b + c] /= closev;
      }
      for c in 0..#vocab_size {
        closev = -10;
        closeid = 0;
        for d in 0..#clcn {
          x = 0;
          for b in LayerSpace do x += cent[layer1_size * d + b] * syn0[c * layer1_size + b];
          if (x > closev) {
            closev = x;
            closeid = d;
          }
        }
        cl[c] = closeid;
      }
    }
    // Save the K-means classes
    for a in 0..#vocab_size {
      var vw = vocab[a].word;
      for j in 0..#vw.len do writer.writef("%c", vw.word[j]);
      writer.write(" ");
      if (binary) then writer.writef("%|4i", cl[a]);
      else writer.write(cl[a]);
      writer.writeln();
    }
  }
  writer.close();
  outputFile.close();
}

// Utilities

inline proc writeSpaceWord(word): int {
  word[0] = ascii('<');
  word[1] = ascii('/');
  word[2] = ascii('s');
  word[3] = ascii('>');
  word[4] = 0;
  return 4;
}

inline proc wordToInt(word: [?] uint(8), len: int): int {
  var cn = 0;
  var x = 1;
  for i in 0..#len by -1 {
    cn += x * (word[i] - 48);
    x *= 10;
  }
  return cn;
}

proc main() {
  for i in 0..#EXP_TABLE_SIZE {
    expTable[i] = exp((i / EXP_TABLE_SIZE:real * 2 - 1) * MAX_EXP); // Precompute the exp() table
    expTable[i] = expTable[i] / (expTable[i] + 1);                   // Precompute f(x) = x / (x + 1)
  }
  TrainModel();
}
