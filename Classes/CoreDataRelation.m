// CoreDataRelation.m
//
// Copyright (c) 2014 Marin Usalj <http://supermar.in>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "CoreDataRelation.h"

#import "NSManagedObject+ActiveRecord.h"

@interface CoreDataRelation ()

@property (copy, nonatomic) NSArray *propertiesToFetch;

@property (weak, nonatomic) Class managedObjectClass;
@property (strong, nonatomic) NSManagedObjectContext *managedObjectContext;

@property (strong, nonatomic) NSManagedObject *managedObject;
@property (copy, nonatomic) NSString *relationshipName;

@property (nonatomic) NSUInteger batchSize;

@end

@implementation CoreDataRelation

@synthesize fetchedObjects = _fetchedObjects;

+ (instancetype)relationWithManagedObjectClass:(Class)class {
    CoreDataRelation *relation = [self new];
    relation.managedObjectClass = class;
    return relation;
}

+ (instancetype)relationWithManagedObject:(NSManagedObject *)record relationship:(NSString *)relationshipName {
    NSRelationshipDescription *relationship = [[record entity] relationshipsByName][relationshipName];
    if (!relationship.isToMany) return nil;

    NSRelationshipDescription *inverseRelationship = [relationship inverseRelationship];
    if (inverseRelationship == nil) return nil;

    Class managedObjectClass = NSClassFromString([[relationship destinationEntity] managedObjectClassName]);
    CoreDataRelation *relation = [self relationWithManagedObjectClass:managedObjectClass];
    relation = [relation where:@"%K = %@", [inverseRelationship name], record];
    relation.managedObjectContext = record.managedObjectContext;
    relation.managedObject = record;
    relation.relationshipName = relationshipName;
    return relation;
}

- (id)init {
    if (self = [super init]) {
        _managedObjectContext = [NSManagedObjectContext defaultContext];
    }
    return self;
}

#pragma mark - Fetch request building

- (instancetype)reverseOrder {
    if ([[self sortDescriptors] count] == 0) {
        id defaultOrder = [self.managedObjectClass defaultOrder];
        if (defaultOrder)
            return [[self order:defaultOrder] reverseOrder];
    }
    return [super reverseOrder];
}

- (instancetype)select:(NSArray *)properties {
    typeof(self) relation = [self copy];
    relation.propertiesToFetch = properties;
    return relation;
}

- (instancetype)inContext:(NSManagedObjectContext *)context {
    typeof(self) relation = [self copy];
    relation.managedObjectContext = context;
    return relation;
}

- (instancetype)inBatchesOf:(NSUInteger)batchSize {
    typeof(self) relation = [self copy];
    relation.batchSize = batchSize;
    return relation;
}

#pragma mark Counting

- (NSUInteger)count {
    if (_fetchedObjects) {
        return [_fetchedObjects count];
    }
    return [self.managedObjectContext countForFetchRequest:[self fetchRequest] error:nil];
}

- (CGFloat)sum:(NSString *)attribute {
    return [self calculate:@"sum" forAttribute:attribute];
}

- (CGFloat)minimum:(NSString *)attribute {
    return [self calculate:@"min" forAttribute:attribute];
}

- (CGFloat)maximum:(NSString *)attribute {
    return [self calculate:@"max" forAttribute:attribute];
}

- (CGFloat)average:(NSString *)attribute {
    return [self calculate:@"average" operator:@"@avg" forAttribute:attribute];
}

- (CGFloat)calculate:(NSString *)function forAttribute:(NSString *)attribute {
    return [self calculate:function operator:nil forAttribute:attribute];
}

- (CGFloat)calculate:(NSString *)function operator:(NSString *)operator forAttribute:(NSString *)attribute {
    if (_fetchedObjects) {
        NSString *keyPathOperator = operator ?: [NSString stringWithFormat:@"@%@", function];
        return [[_fetchedObjects valueForKeyPath:[NSString stringWithFormat:@"%@.%@", keyPathOperator, attribute]] doubleValue];
    }

    NSExpression *keyPathExpression = [NSExpression expressionForKeyPath:attribute];
    NSExpression *functionExpression = [NSExpression expressionForFunction:[NSString stringWithFormat:@"%@:", function]
                                                                 arguments:@[keyPathExpression]];

    NSExpressionDescription *description = [NSExpressionDescription new];
    [description setName:function];
    [description setExpression:functionExpression];
    [description setExpressionResultType:NSDoubleAttributeType];

    NSFetchRequest *fetchRequest = [self fetchRequest];
    [fetchRequest setPropertiesToFetch:@[description]];
    [fetchRequest setResultType:NSDictionaryResultType];

    NSArray *results = [self.managedObjectContext executeFetchRequest:fetchRequest error:nil];
    return [[results firstObject][function] doubleValue];
}

#pragma mark -

- (NSArray *)fetchedObjects {
    if (_fetchedObjects == nil) {
        NSArray *objects = [self.managedObjectContext executeFetchRequest:[self fetchRequest] error:nil];
        if (self.sectionNameKeyPath) {
            objects = [[self class] sectionObjects:objects byKeyPath:self.sectionNameKeyPath];
        }
        _fetchedObjects = objects;
    }
    return _fetchedObjects;
}

- (NSFetchRequest *)fetchRequest {
    NSFetchRequest *fetchRequest = [NSFetchRequest new];
    NSEntityDescription *entity = [NSEntityDescription entityForName:[self.managedObjectClass entityName]
                                              inManagedObjectContext:self.managedObjectContext];
    [fetchRequest setEntity:entity];
    [fetchRequest setFetchBatchSize:self.batchSize];
    [fetchRequest setFetchLimit:self.limit];
    [fetchRequest setFetchOffset:self.offset];
    [fetchRequest setPredicate:[self predicate]];
    [fetchRequest setSortDescriptors:[self sortDescriptors]];

    if (self.propertiesToFetch) {
        NSMutableArray *properties = [NSMutableArray new];
        NSDictionary *propertiesByName = [entity propertiesByName];

        for (NSString *property in self.propertiesToFetch)
            [properties addObject:propertiesByName[property]];

        [fetchRequest setPropertiesToFetch:properties];
        [fetchRequest setResultType:NSDictionaryResultType];
    }

    return fetchRequest;
}

- (NSArray *)sortDescriptors {
    NSArray *sortDescriptors = [super sortDescriptors];

    if ([sortDescriptors count] == 0) {
        id defaultOrder = [self.managedObjectClass defaultOrder];
        if (defaultOrder)
            return [[self order:defaultOrder] sortDescriptors];
    }

    return sortDescriptors;
}

#pragma mark - Manipulating entities

- (id)findOrCreate:(NSDictionary *)properties {
    NSDictionary *transformed = [self.managedObjectClass transformProperties:properties withContext:self.managedObjectContext];

    return [[self where:transformed] firstObject] ?: [self create:transformed];
}

- (id)create {
    return [NSEntityDescription insertNewObjectForEntityForName:[self.managedObjectClass entityName]
                                         inManagedObjectContext:self.managedObjectContext];
}

- (id)create:(NSDictionary *)attributes {
    if (attributes == nil || (id)attributes == [NSNull null]) return nil;

    NSManagedObject *record = [self create];
    [record update:attributes];

    if (self.managedObject && self.relationshipName) {
        [[self.managedObject mutableSetValueForKey:self.relationshipName] addObject:record];
    }

    return record;
}

- (void)updateAll:(NSDictionary *)attributes {
    for (NSManagedObject *record in self) {
        [record update:attributes];
    }
}

- (void)deleteAll {
    for (NSManagedObject *record in self) {
        [record delete];
    }
}

#pragma mark - NSObject

- (NSString *)description {
    NSString *description = [super description];

    NSString *append = [NSString stringWithFormat:@" managedObjectClass: %@; managedObjectContext: %@; managedObject: %@; relationshipName: %@; batchSize: %lu>", self.managedObjectClass, self.managedObjectContext, self.managedObject, self.relationshipName, (unsigned long)self.batchSize];

    return [description stringByReplacingCharactersInRange:NSMakeRange([description length] - 2, 1) withString:append];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    typeof(self) copy = [super copyWithZone:zone];
    if (copy) {
        copy.managedObjectClass = self.managedObjectClass;
        copy.managedObjectContext = self.managedObjectContext;
        copy.managedObject = self.managedObject;
        copy.relationshipName = self.relationshipName;
        copy.batchSize = self.batchSize;
    }
    return copy;
}

@end
